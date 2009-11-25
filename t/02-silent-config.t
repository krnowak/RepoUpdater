#! /usr/bin/perl

use Test::More;

use Cwd;
use File::Basename;
use File::Spec;

BEGIN
{
	use_ok( 'RepoUpdater' );
}

#
# global stuff
#
my $testfile = 'empty';

#
# config stuff
#
my $cwd = getcwd();

# code taken from Config::Auto.
my $whoami = basename($0);
my $bindir = dirname($0);
$whoami =~ s/\.(pl|t)$//;

my $config = {
              'paths' => [File::Spec->catdir($cwd, $bindir, 'repos')],
              'tools' => ['a', 'b'],
              'a-dir' => '.a',
              'a-name' => 'a',
              'a-commands' => ['touch ' . $testfile, 'rm ' . $testfile],
              'b-dir' => '.b',
              'b-name' => 'b',
              'b-commands' => ['touch ' . $testfile, 'rm ' . $testfile]
             };

#
# handler stuff
#
my $current_project;

sub silent {}

sub pre_update
{
  my $data = shift;
  my $path = $data->{'path'};
  my @dirs = File::Spec->splitdir($path);
  $current_project = $dirs[$#dirs];
}

sub pre_command
{
  my $data = shift;
  my $command = $data->{'command'};
  like($command, qr/(rm)|(touch)/, 'command is one of specified.') or return;
  if ($command =~ /touch/)
  {
    ok(! -e $testfile, 'before ' . $command) or diag($testfile . ' should not exist in ' . $current_project . ' before executing ' . $command);
  }
  else
  {
    ok(-e $testfile, 'before ' . $command) or diag($testfile . ' should exist in ' . $current_project . ' before executing ' . $command);
  }
}

sub post_command
{
  my $data = shift;
  my $command = $data->{'command'};
  like($command, qr/(rm)|(touch)/, 'command is one of specified.') or return 0;
  if ($command =~ /touch/)
  {
    ok(-e $testfile, 'after ' . $command) or diag($testfile . ' should exist in ' . $current_project . ' after executing ' . $command);
  }
  else
  {
    ok(! -e $testfile, 'after ' . $command) or diag($testfile . ' should not exist in ' . $current_project . ' after executing ' . $command);
  }
  0;
}

# create silent repo updater - we do not want to clutter screen.
my $ru = RepoUpdater->new(pre_u_h => \&pre_update,
                          pre_c_h => \&pre_command,
                          post_c_h => \&post_command,
                          post_u_h => \&silent,
                          config => $config,
                          print_output => 0);

ok(defined ($ru), 'new creates object');
is(ref($ru), 'RepoUpdater', 'new creates RepoUpdater instance');
cmp_ok($ru->repo_count(), '==', 3, 'repo_count');
cmp_ok($ru->updated_repo_count() , '==', 0, 'updated_repo_count');
cmp_ok($ru->not_updated_repo_count(), '==', 3, 'not_updated_repo_count()');
$ru->update_one();
cmp_ok($ru->updated_repo_count(), '==', 1, 'updated_repo_count after first.');
cmp_ok($ru->not_updated_repo_count(), '==', 2, 'not_updated_repo_count after first.');
$ru->update_one();
cmp_ok($ru->updated_repo_count(), '==', 2, 'updated_repo_count after second.');
cmp_ok($ru->not_updated_repo_count(), '==', 1, 'not_updated_repo_count after second.');
$ru->rewind_one();
cmp_ok($ru->updated_repo_count(), '==', 1, 'updated_repo_count after rewind one.');
cmp_ok($ru->not_updated_repo_count(), '==', 2, 'not_updated_repo_count after rewind one.');
$ru->update();
cmp_ok($ru->updated_repo_count(), '==', 3, 'updated_repo_count after update.');
cmp_ok($ru->not_updated_repo_count(), '==', 0, 'not_updated_repo_count after update.');
$ru->rewind();
cmp_ok($ru->updated_repo_count(), '==', 0, 'updated_repo_count after rewind.');
cmp_ok($ru->not_updated_repo_count(), '==', 3, 'not_updated_repo_count after rewind.');

done_testing();
