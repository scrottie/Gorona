package Gorona;

use 5.010000;
use strict;
use warnings;

our $VERSION = '0.01';



1;
__END__

=head1 NAME

Gorona - Coro based PSGI web server... for Gopher

=head1 SYNOPSIS
  
  gorona app.psgi

=head1 DESCRIPTION

XXX todo: use L<Coro::AIO> (and L<IO::AIO>) if available, to send the static filehandle using sendfile(2).

XXX todo:  set C<psgi.multithread> env var on.

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

