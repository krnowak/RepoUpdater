use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
    module_name         => 'RepoUpdater',
    license             => 'perl',
    dist_author         => 'Krzesimir Nowak <qdlacz@gmail.com>',
    dist_version_from   => 'lib/RepoUpdater.pm',
    build_requires => {
        'Test::More' => 0,
    },
    add_to_cleanup      => [ 'RepoUpdater-*' ],
    create_makefile_pl => 'traditional',
);

$builder->create_build_script();
