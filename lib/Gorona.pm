package Gorona;

use 5.010000;
use strict;
use warnings;

our $VERSION = '0.01';



1;
__END__

=head1 NAME

Gorona - Coro based PSGI web server... for Gopher (with apologies to Miyagawa and his Corona)

=head1 SYNOPSIS
  
  gorona app.psgi

=head1 DESCRIPTION

Gopher has long been the preferred hypertext protocol, offering rich media, metadata annotation,
rich forms, accessibility, high performance, fantastic content, and a lack of utterly bullshit content
such as L<http://myspace.com>, but has thus far been lacking is a generic stack for mounting 
dynamic applications.
Enter L<Gorona>, the first L<Rack> inspired server for Gopher.

Since Gopher is essentially a superset of HTML/HTTP except for the stupid parts, goronaiaing up 
your existing Web app should just work (note:  JavaScript support is not implemented at this time).

Uses L<Coro::AIO> (and L<IO::AIO>) if available, to send the static filehandle using C<sendfile(2)>.

Sets C<psgi.multithread> env var on.

=head1 HISTORY

Original version; created by h2xs 1.23 with options

  -A -C -X -b 5.10.0 -n Gorona v 0.1

=head1 AUTHOR

Scott Walters with code taken from Tatsuhiko Miyagawa's work

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.12.3 or,
at your option, any later version of Perl 5 you may have available.

=head1 SEE ALSO

A professional.
