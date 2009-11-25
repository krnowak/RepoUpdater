#! /usr/bin/perl

use Test::More tests => 1;

BEGIN
{
	use_ok( 'RepoUpdater' );
}

diag( "Testing RepoUpdater $RepoUpdater::VERSION, Perl $], $^X" );
