package Plack::Handler::Gorona;

use strict;
use Gorona::Server;

sub new {
    my $class = shift;
    bless { @_ }, $class;
}

sub run {
    my($self, $app) = @_;

    my $server = Gorona::Server->new( );
    $server->{app} = $app;
    $server->run(port => $self->{port});
}

1;

__END__

=head1 NAME

Plack::Handler::Gorona - Gopher adapter for Plack

=head1 SYNOPSIS

  plackup -s Gorona app.psgi

=head1 SEE ALSO

L<Net::Gopher> L<Gopher::Server> L<Corona> L<Plack>

=cut
