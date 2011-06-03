use inc::Module::Install;
name 'Gorona';
all_from 'lib/Gorona.pm';
readme_from 'lib/Gorona.pm';
requires 'Coro';
requires 'Net::Server::Coro', 0.5;
requires 'Plack', 0.99;
requires 'HTML::Parser';
requires 'HTML::TreeBuilder';
requires 'Text::FIGlet';
# requires 'File::ShareDir';
# requires 'Net::Gopher' => 0.1;                     # bringing it back from the backpan ... no, if we're translating to HTTP style, easier to just
# requires 'Gopher::Server::Response';               # do it ourselves instead, for now
build_requires 'Test::More';
install_script 'bin/gorona';

# use inc::Module::Install::Share; # well, that doesn't bloody work
# install_share 'figlet';

use Config;
my $sharedir = $Config{scriptdir};
$sharedir =~ s{/bin$}{/share};
warn "Installing figlet fonts to $sharedir.";
system 'cp', '-r', 'figlet', $sharedir and warn;

auto_set_repository;
WriteAll;
