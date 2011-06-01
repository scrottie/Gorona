package Gorona::Server;

use strict;
use warnings; # XXX
use 5.010;

=for comment

Todo:

o. load up the old Net::Gopher::Response::MenuItem / InformationBlock classes and offer that as an API for $response->[2] / body. 
   monkey patch Plack::Response...?
o. handle cookies by turning them into cgi-like args and adding them to the requester, and setting them from there again on next hit
   ... or else have a %cookies of global scope keyed on IP address like we started doing with form field info?
o. what happens if we don't have AIO and it is a real filehandle?  in that case, it looks like we try to send the fh as text
o. in case of a HEAD request, actually send the HTTP header key/value pairs as the document; also send +ADMIN and +INFO blocks as required
o. special handing for Net::Gopher::Response::MenuItem objects in the body array?

Done-ish:

o. translate the HTML

=cut

use base 'Net::Server::Coro';
use Plack::Util;

use constant HAS_AIO => !$ENV{PLACK_NO_SENDFILE} && eval "use Coro::AIO; 1";

use HTTP::Status;
use HTML::Parser;
use Scalar::Util;
use List::Util qw(sum max);
use Text::Wrap;

my %forms;
my $hostname = `hostname`; chomp $hostname;

sub process_request {
    my $self = shift;

    my $fh = $self->{server}{client};

    my $env = {
        REQUEST_METHOD => 'GET',
        SERVER_PORT => $self->{server}{port}[0] || $self->port || die,
        SERVER_NAME => $self->{server}{host}[0],
        SCRIPT_NAME => '',
        REMOTE_ADDR => $self->{server}{peeraddr},
        'psgi.version' => [ 1, 0 ],
        'psgi.errors'  => *STDERR,
        'psgi.input'   => $self->{server}{client},
        'psgi.url_scheme' => 'gopher', # 'http' # SSL support?
        'psgi.nonblocking'  => Plack::Util::TRUE,
        'psgi.run_once'     => Plack::Util::FALSE,
        'psgi.multithread'  => Plack::Util::TRUE,
        'psgi.multiprocess' => Plack::Util::FALSE,
        'psgi.streaming'    => Plack::Util::TRUE,
        'psgix.io'          => $fh->fh,
    };

    $env->{SERVER_NAME} = $hostname if $env->{SERVER_NAME} eq '*';

    my $res = [ 400, [ 'Content-Type' => 'text/plain' ], [ 'Bad Request' ] ];

    my $request = $fh->readline("\015\012") or goto just_send_the_default_error_response_then;
    do { local $/ = "\r\n"; chomp $request; };

warn "request: ``$request''";

    # according to gopher://gopher.floodgap.com/0/gopher/tech/gopherplus.txt, this is the format of the first (required) line of
    # a gopher request (nothing that the selectorstring may be null, hence the request just a CRLF, and "F" is \t):
    #
    # selectorstringF+[representation][FdataFlag]<CRLF>[datablock]
    #
    # but then it goes on to correct itself to say that if search terms are provided, then it is essentially this (my edit):
    #
    # selectorstringFsearchwordsF+[representation][FdataFlag]<CRLF>[datablock]


    my @request = split m/\t/, $request;
    $request[0] = '/' if ! length $request[0]; 
    $env->{REQUEST_URI} = $request[0]; # XXXX add ?x=y;z=q form params to selector and stuff it in here

warn "request uri: ``$request[0]''";

    # From http://gopher.quux.org:70/Archives/Mailing%20Lists/gopher/gopher.2002-02%3F/MBOX-MESSAGE/34 :
    # When a conforming Gopher server receives a request whose path begins
    # with URL:, it will write out a HTML document that will send the
    # non-compliant browser to the appropriate place.

    if( $request[0] =~ m/^URL:/ ) {
        (my $url = $request[0]) =~ s{^URL:}{};
        my $html = qq{
            <HTML>
            <HEAD>
            <META HTTP-EQUIV="refresh" content="2;URL=$url">
            </HEAD>
            <BODY>
            You are following a link from gopher to a web site.  You will be
            automatically taken to the web site shortly.  If you do not get sent
            there, please click <A HREF="$url">here</A> to go to the web site.
            <P>
            The URL linked is:
            <P>
            <A HREF="$url">$url</A>
            <P>
            Thanks for using gopher!
            </BODY>
            </HTML>
        };
        $res = [ 200, [ 'Content-Type' => 'text/plain' ], [ $html ] ];   # text/plain to send the HTML as plain text as if it were a file download
        warn "handled a URL: selector by sending HTML"; # XXX
        goto just_send_the_default_error_response_then;
    }

    my($path, $query) = ( $request[0] =~ /^([^?]*)(?:\?(.*))?$/s );
    $env->{PATH_INFO} = $path;
    $env->{QUERY_STRING} = $query || '';

    my $gopherplus_info = '';
    my $metainfo_request = 0;
    my %params;
    # try to sort out all of the variable position positional parameters

    $env->{SERVER_PROTOCOL} = 'GOPHER';

    my $uploading = 0;

    my $likely_gopherplus = sub { my $str = shift; return 1 if length( $str ) >= 2 and substr( $str, 0, 1 ) eq '+'; };

    if( @request >= 2 ) {
        if( $likely_gopherplus->( $request[1] ) ) {
            $gopherplus_info = $request[1];
            $uploading = $request[2] if @request >= 3;
        } else {
            $params{search} = $request[1];
            if( @request >= 3 and $likely_gopherplus->( $request[2] ) ) {
                $gopherplus_info = $request[2];
                $uploading = $request[3] if @request >= 4;
            }
        }
    }

    if( $gopherplus_info ) {
        substr( $gopherplus_info, -1, 1 ) eq '+' or do { warn "bad req XXX"; goto just_send_the_default_error_response_then; };
        $env->{SERVER_PROTOCOL} = 'GOPHER+';
        # $env->{REQUEST_METHOD} = 'HEAD' if length($gopherplus_info) == 2 and substr( $gopherplus_info, 1, 1 ) eq '!' and ! $uploading;  # POST and HEAD probably shouldn't be mutually exclusive
        $metainfo_request = 1 if length($gopherplus_info) == 2 and substr( $gopherplus_info, 1, 1 ) eq '!' and ! $uploading;
    }

warn "protocol: $env->{SERVER_PROTOCOL}  uploading: $uploading";

    my $upload;

    if( $uploading ) {
        $env->{REQUEST_METHOD} = 'POST';
        # same format as when we write to the client, supposedly: "+$length\r\n"
        my $uploadspec = $fh->readline("\015\012") or do { warn "debug: failed to read uploadspec line"; goto just_send_the_default_error_response_then; };
        do { local $/ = "\r\n"; chomp $uploadspec; };
        my $gopherplus_plus = substr( $uploadspec, 0, 1, '' ) eq '+' or do { warn "debug: uploadspec didn't start with a + for success"; goto just_send_the_default_error_response_then; }; # XXX no, should send better error codes
        warn "upload length: $uploadspec";
        if( $uploadspec < 0 ) { warn "debug: uploadspec < 0: $uploadspec"; goto just_send_the_default_error_response_then; }; # XXX better error 
        if( $uploadspec > 0 ) { read $fh, $upload, $uploadspec; }
    }

    # XXX add %params to $env->{QUERY_STRING}

    # XXX okay, now what to do with the uploaded data?


    #
    #
    #

    $res = Plack::Util::run_app $self->{app}, $env;

  just_send_the_default_error_response_then:


    if (ref $res eq 'ARRAY') {
        # PSGI standard
warn "sending response with code: $res->[0]";
        $self->_write_response($res, $fh, undef, $metainfo_request, $env);
    } elsif (ref $res eq 'CODE') {
        # delayed return
        my $cb = Coro::rouse_cb;
        $res->(sub {
warn "sending response with code: $_[0]->[0]";
            $self->_write_response(shift, $fh, $cb, $metainfo_request, $env);
        });
        Coro::rouse_wait $cb;
    }
}

sub _write_response {
    my($self, $res, $fh, $rouse_cb, $metainfo_request, $env) = @_;

    my @lines;

    # my $resob = Plack::Response->new( @$res );
    my %headers = @{ $res->[1] };
    my $content_type = $headers{'Content-Type'} || '';
    $content_type =~ s{;.*}{};

    if( HTTP::Status::is_error( $res->[0] ) ) {

        my $html = join '', @{ $res->[2] } || '';
        $html = ': ' . $html if $html;
        $html =~ s{<.*?>}{}gs;
        $html =~ s{\r?\n}{}gs;

# XXX gopher error codes:
#        1       Item is not available.
#        2       Try again later ("eg.  My load is too high right now.")
#        3       Item has moved.  Following the error-code is the  gopher descriptor of where it now lives.

        $html =  HTTP::Status::status_message( $res->[0] ) . "\r\n" . $html;

        if( $env->{SERVER_PROTOCOL} eq 'GOPHER+' ) {
            $fh->syswrite("-@{[ $res->[0] ]}\r\n$html\r\n.\r\n");
        } else {
            $fh->syswrite( join '', map "i$_\t\t\t\r\n", split m/\r?\n/, Text::Wrap::wrap('', '', $html) ); # info menu style... other options? XXX
        }

    } elsif( $content_type eq 'text/html' ) {

        # success; text/html case; translate to gopher menus

        # XXXXX compute cookies part of the selector to be added to each selector created by the HTML translation routine
        # XXXXX if it's a gopherplus meta-info request (which is when we tell it about form fields) then translate_html() does something different

        # defeat any attempts at streaming so that we can translate the HTML

        # no header gets sent; gopher expects menus and info blocks without file trasfer headers

        my $buffer = '';

        if( ! defined $res->[2] ) {
            # streaming write; sorry, no streaming HTML.
            # most of these fall-through to the $rouse_cb->() at the bottom; this one returns early and rouses later.
            return Plack::Util::inline_object write => sub { 
                $buffer .= join '', @_;
            }, close => sub {
                $buffer = translate_html($buffer, $metainfo_request, $env);
                $fh->syswrite($buffer); 
                $rouse_cb->();
            };
        } elsif (HAS_AIO && Plack::Util::is_real_fh($res->[2])) {
            while( my $chunk = $res->[2]->readline('') ) {
                $buffer .= $chunk;
            }
        } else {
            $buffer = join '', @{ $res->[2] };
        }

        $buffer = translate_html($buffer, $metainfo_request, $env);
        $fh->syswrite($buffer);
    
    } else {

        # success; send it as a file (might be gopher menu data!)

        if( ! defined $res->[2] ) {
            # streaming write
            $fh->syswrite("+-2\r\n") if $env->{SERVER_PROTOCOL} eq 'GOPHER+';   # header:  streamed data until connection close
            return Plack::Util::inline_object write => sub { $fh->syswrite(join '', @_) }, close => $rouse_cb;
        } elsif (HAS_AIO && Plack::Util::is_real_fh($res->[2])) {
            my $length = -s $res->[2];
            $fh->syswrite("+$length\r\n") if $env->{SERVER_PROTOCOL} eq 'GOPHER+';   # header:  streamed fixed length
            my $offset = 0;
            while (1) {
                my $sent = aio_sendfile( $fh->fh, $res->[2], $offset, $length - $offset );
                $offset += $sent if $sent > 0;
                last if $offset >= $length;
            }
        } else {
            $fh->syswrite("+-2\r\n")  if $env->{SERVER_PROTOCOL} eq 'GOPHER+';   # header:  streamed data until connection close
            Plack::Util::foreach($res->[2], sub { $fh->syswrite(join '', @_) });
        }


    }  # success/failure/html/file
    
    $rouse_cb->() if $rouse_cb;
}

sub translate_html {

    my $html = shift;
    my $metainfo_request = shift;
    my $env = shift;

    my $servername = $env->{SERVER_NAME} or die;
    my $port = $env->{SERVER_PORT} or die;

    my $remoteaddr = $env->{REMOTE_ADDR} or die; #  XXX start using cookies or something for this in the future


    my $cb;
    my $output;

    if( $metainfo_request ) {

        # client only wants to know about form fields

        # eg:
        # +ASK:
        #  Ask: How many volts?
        #  Choose: Deliver electric shock to administrator now?\tYes\tNot!

        $output = "+ASK:\r\n";
        my $last_bit_of_text;
        my $select_name;
        my $select_text;
        my @options;
        my $style;

        $forms{$remoteaddr} = \my @form;  # remember what questions we asked them so we can reconstruct a query string later.. ugh

        $cb = sub {

           my $event = shift;

            if( $event eq 'text' ) {
                $last_bit_of_text = shift;
                $last_bit_of_text =~ s{[\r\n\t]}{ }g;
                return;
            }
            my $tag = shift;
            my $attr = shift;

            my $name = $attr->{name} || '';
            my $value = $attr->{value} || '';

            if( $tag eq 'style' or $tag eq 'script' ) {
                $style = 1; # ignore text
            } elsif( $tag eq '/style' or $tag eq '/script' ) {
               $style = 0;
            } elsif( $tag eq 'textarea' ) {
                $output .= " AskL: $last_bit_of_text\r\n";
                push @form, [ $name, undef ];
            } elsif( $tag eq 'select' ) {
                $select_name = $attr->{name};
                $select_text = $last_bit_of_text;
            } elsif( $tag->tag eq 'option' ) {
                push @options, $attr->{value};
            } elsif( $tag->tag eq '/select' ) {
                my $type = $attr->{multiple} ? "Select" : "Choose"; # select is one or many; choose is one
                $output .= " $type: $select_text\t" . join "\t", @options;
                $output .= "\r\n";
                push @form, [ $select_name, 1 ];
            } elsif( $tag eq 'input' ) {
                my $type = lc $attr->{type};
                if( $type eq 'text' ) {
                    $output .= " Ask: $last_bit_of_text\t$value\r\n"; # XXX said I could provide a default but didn't say how...
                    push @form, [ $name, undef ];
                } elsif( $type eq 'password' ) {
                    $output .= " AskP: $last_bit_of_text\r\n";
                    push @form, [ $name, undef ];
                } elsif( $type eq 'file' ) {
                    $output .= " ChooseF: $last_bit_of_text\r\n";
                    push @form, [ $name, 2 ];
                }
                # XXX ... multiple submit values should work like select/option lists
                # XXX ... more
            }
        };

    } else {

        # delivering the full page to the client as a menu
        # standard menu but all items end in ? indicating that the client should request the attributes/metainfo
        # translate text, links and buttons

       $Text::Wrap::columns = 72;

       my $last_bit_of_text;
       my $pending_href;
       my $style;

       $cb = sub {
           my $event = shift;
# warn "cb: " . join ' ', map ">>$_<<", @_;
           if( $event eq 'text' ) {
               return if $style;
               my $text = shift;
               $text =~ s{<!--.*?-->}{}sg; # JavaScript, mostly
               return if $text =~ m/^\s*$/;
# warn "text: $text";
               ( $last_bit_of_text = $text ) =~ s{[\r\n\t]}{ }g;
# warn "last_bit_of_text: $last_bit_of_text";
               $output .= join '', map "i$_\t\t\t\r\n", split m/\r?\n/, Text::Wrap::wrap('', '', $text);
# warn "appending text: " . join '', map "i$_\r\n", split m/\r?\n/, Text::Wrap::wrap('', '', $text);
               return;
           }
           my $tag = shift;
           my $attr = shift;
           if( $tag eq 'style' or $tag eq 'script' ) {
               $style = 1; # ignore text
           } elsif( $tag eq '/style' or $tag eq '/script' ) {
               $style = 0;
           } elsif( $tag eq 'a' and $attr->{href} ) {
# use Data::Dumper; warn Data::Dumper::Dumper($attr);
               $pending_href = $attr;
           } elsif( $tag eq '/a' and $pending_href ) {
               # XXX actually take the servername and port off of the href
               my $href = $pending_href->{href};
               return if $href =~ m/^#/;
               if( $href =~ m{^/} ) {
                   $output .= "1" . $last_bit_of_text . "\t" . $href . "\t" . $servername . "\t" . $port . "\t" . "?" . "\r\n";
               } else {
                   my $uri = URI->new($href);
                   if( $uri->host eq $servername ) {
                       $output .= "1" . $last_bit_of_text . "\t" . $uri->path . "\t" . $servername . "\t" . $port . "\t" . "?" . "\r\n";
                   } else {
                       # from http://gopher.quux.org:70/Archives/Mailing%20Lists/gopher/gopher.2002-02%3F/MBOX-MESSAGE/34 :
                       # Type -- the appropriate character corresponding to the type of the
                       # document on the remote end; h if HTML.
                       # Path -- the full URL, preceeded by "URL:".  For instance:
                       #         URL:http://www.complete.org/
                       # Host, Port -- pointing back to the gopher server that provided
                       # the directory for compatibility reasons.
                       $output .= "h" . $last_bit_of_text . "\t" . "URI:".$href . "\t" . $servername . "\t" . $port . "\t" . "?" . "\r\n";
                   }
               }
           } elsif( $tag eq 'img' and $attr->{src} ) {
               $output .= "I" . $last_bit_of_text . ' ' . ($attr->{alt}||'') . "\t" . $attr->{src} . "\t" . $servername . "\t" . $port . "\r\n";
           }

       };

    };

    my $p = HTML::Parser->new(
       api_version => 3,
       handlers => { 
           text =>  [ $cb, "event,text"],
           start => [ $cb, "event,tag,attr,text"],
           end =>   [ $cb, "event,tag"],
           comment => [ sub { }, 'event'],
       }, 
    );
    $p->unbroken_text( 1 );
    $p->parse($html);
    $p->eof;

warn substr $output, 0, 8192; # XXX

    return $output;

}

1;

__END__


#    my $crawl_tree;  $crawl_tree = sub {
#        my $parent_node = shift;
#        # my @children = $parent_node->guts;
#        my @children = $parent_node->content_list;
#        if( @children ) {
#            for my $node (@children) {
#                $crawl_tree->( $node );
#            }
#        } else {
#            # leaf
#            $cb->( $parent_node );
#        }
#    };
#    $crawl_tree->($tree);

    my $tree = HTML::TreeBuilder->new_from_content($html);
    $tree->traverse(
      sub {
          my ($node, $start) = @_;
          my $tag;
          if(ref $node) {
            $tag = $node->{'_tag'};
            # push(@html, $node->starttag($entities));
            $cb->($node, $start);
          } else {
            # simple text content
            HTML::Entities::encode_entities($node); #  unless $HTML::Tagset::isCDATA_Parent{ $_[3]{'_tag'} }
            # push(@html, $node);
            $cb->($node);
          }
         1; # keep traversing
        }
    ); # End of parms to traverse()

    $tree = $tree->delete;


