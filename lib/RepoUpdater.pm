package RepoUpdater;

use strict;
use warnings;

use Carp;
use Config::Auto;
use Cwd;
use File::HomeDir;
use File::Spec;
use File::Temp qw( tempfile unlink0 );
use IO::CaptureOutput qw( qxy );
use IO::Dir;
use IO::File;
use Term::ANSIColor;

=head1 NAME

RepoUpdater - Configurable code repository updater.

=head1 VERSION

Version 0.02

=cut

our $VERSION = '0.02';

=head1 SYNOPSIS

    use RepoUpdater;

    # Default verbose updater:
    my $ru = RepoUpdater->new();

    # Partially custom updater:
    my $ru = RepoUpdater->new(pre_u_h => \&func1, post_c_h => \&func2);

    # Get repo count:
    my $r_c = $ru->repo_count();

    # Start updating:
    $ru->update();

=head1 DESCRIPTION

This module serves one simple purpose: to update your source repositories. For
this to work you have to write a proper configuration file and put it in proper
place. More on this is in C<CONFIGURATION>.

=cut

#
# internal globals
#
my $p_opt = 'paths';
my $t_opt = 'tools';
my $d_suffix = '-dir';
my $n_suffix = '-name';
my $c_suffix = '-commands';

#
# internal functions.
#

#
# _check_and_convert
# params:
#   hashref - config.
#   scalar - key.
# returns:
#   hashref - config with checked and converted key. config is changed in place.
#
# croaks if key does not exist in config. converts scalars to arrayrefs. joins
# space separated words inside double quotes. unescapes inside double quotes.
#
sub _check_and_convert
{
  my $config = shift;
  my $key = shift;

  croak 'no ' . $key . ' specified.' unless exists $config->{$key};
  unless (ref($config->{$key}))
  {
    $config->{$key} = [$config->{$key}];
  }
  croak $key . ' is not a reference to array.' unless (ref($config->{$key}) eq "ARRAY");
  my @new_values = ();
  my $temp_value = "";
  my $inside_dq = 0;
  foreach my $line (@{$config->{$key}})
  {
    unless ($inside_dq)
    {
      # if line is quoted from start to end.
      if ($line =~ /^"(.*[^\\])"$/)
      {
        $line = $1;
      }
      # else if line is quoted only from start.
      elsif ($line =~ /^"(.*)$/)
      {
        $line = $1 . " ";
        $inside_dq = 1;
      }
    }
    #if line is quoted only at end.
    else
    {
      if ($line =~ /^(.*[^\\])"$/)
      {
        $line = $1;
        $inside_dq = 0;
      }
      else
      {
        $line .= " ";
      }
    }
    $temp_value .= $line;
    unless ($inside_dq)
    {
      # remove backslashes.
      $temp_value =~ s/\\//g;
      push @new_values, $temp_value;
      $temp_value = "";
    }
  }
  $config->{$key} = \@new_values;
  $config;
}

#
# _check_one
# params:
#   hashref - config.
#   scalar - key.
# returns:
#   hashref - config with checked key.
#
# croaks if key does not exist in config. croaks if key is some sort of ref.
#
sub _check_one
{
  my $config = shift;
  my $key = shift;

  croak 'no ' . $key . ' specified.' unless exists $config->{$key};
  croak 'more than one ' . $key . ' specified.' if ref($config->{$key});
  $config;
}

#
# _convert_s_to_a
# params:
#   hashref - config.
# returns:
#   hashref - config with proper fields checked and converted. config is changed
#             in place.
#
# croaks if config is not hashref. checks and converts keys in config. config
# has to containg paths (arrayref or scalar), tools (arrayref or scalar) and
# -dir (scalar), -name (scalar), -commands (arrayref or scalar) for every value
# in tools key.
#
sub _convert_s_to_a
{
  my $config = shift;

  croak 'given configuration is not a reference to hash.' unless (ref($config) eq "HASH");
  _check_and_convert($config, $p_opt);
  _check_and_convert($config, $t_opt);
  foreach my $tool (@{$config->{$t_opt}})
  {
    _check_one($config, $tool . $d_suffix);
    _check_one($config, $tool . $n_suffix);
    _check_and_convert($config, $tool . $c_suffix);
  }
  $config;
}

#
# _strip_trailing_slashes
# params:
#   hashref - config.
# returns:
#   hashref - config with paths stripped from trailing slashes. config is
#             changed in place.
#
# strips trailing slashes from paths in config. convert has to contain paths
# (arrayref) key.
#
sub _strip_trailing_slashes
{
  my $config = shift;
  my @new_paths = ();

  foreach my $path (@{$config->{$p_opt}})
  {
    push @new_paths, File::Spec->catdir($path);
  }
  $config->{$p_opt} = \@new_paths;
  $config;
}


#
# convert_r_to_a
# params:
#   hashref - config.
# returns:
#   hashref - config with converted paths. config is changed in place.
#
# converts relative paths to absolute ones in config. config has to contain
# paths (arrayref) key. also removes nonexistent paths.
#
sub _convert_r_to_a
{
  my $config = shift;
  my @existent_paths = ();
  foreach my $r_path (@{$config->{$p_opt}})
  {
    my $a_path;
    unless (File::Spec->file_name_is_absolute($r_path))
    {
      $a_path = File::Spec->rel2abs($r_path, File::HomeDir->my_home);
    }
    else
    {
      $a_path = $r_path;
    }
    if (-d $a_path)
    {
      push @existent_paths, $a_path;
    }
  }
  $config->{$p_opt} = \@existent_paths;
  $config;
}

#
# _get_subdirs
# params:
#   scalar - path.
# returns:
#   arrayref - subdirs.
#
# gets dirs in a path.
#
sub _get_subdirs
{
  my $path = shift;
  my $dir_handle = IO::Dir->new($path);
  my @subdirs = ();
  if (defined $dir_handle)
  {
    while (defined (my $entry = $dir_handle->read))
    {
      if ($entry eq "." or $entry eq "..")
      {
        next;
      }
      my $full_entry = File::Spec->catdir($path, $entry);
      if (-d $full_entry)
      {
        push @subdirs, $full_entry;
      }
    }
    $dir_handle->close;
  }
  return \@subdirs;
}

#
# _expand_paths
# params:
#   hashref - config.
# returns:
#   hashref - config with expanded paths.
#
# expands paths in config to "leaf" paths, that is - to ones containing repos.
#
sub _expand_paths
{
  my $config = shift;
  my @new_paths = ();
  foreach my $path (@{$config->{$p_opt}})
  {
    my @sub_paths = ($path);
    foreach my $sub_path (@sub_paths)
    {
      my $is_repo = 0;
      foreach my $tool (@{$config->{$t_opt}})
      {
        my $dir = File::Spec->catdir($sub_path, $config->{$tool . $d_suffix});
        if (-d $dir)
        {
          $is_repo = 1;
          push @new_paths, $sub_path;
          last;
        }
      }
      unless ($is_repo)
      {
        push @sub_paths, @{_get_subdirs($sub_path)};
      }
    }
  }
  $config->{$p_opt} = \@new_paths;
  $config;
}

#
# _unique_paths
# params:
#   hashref - config.
# returns:
#   hashref - config with unique paths.
#
# removes redundant paths in config.
#
sub _unique_paths
{
  my $config = shift;
  my @unique_paths = ();
  my %u_p_h = ();
  
  foreach my $path (@{$config->{$p_opt}})
  {
    unless (exists($u_p_h{$path}))
    {
      push @unique_paths, $path;
      $u_p_h{$path} = 1;
    }
  }
  $config->{$p_opt} = \@unique_paths;
  $config;
}

#
# _prepare
# params:
#   hashref - config.
# returns:
#   hashref - prepared config.
#
# prepares config taken from Config::Auto.
#
sub _prepare
{
  my $config = _convert_r_to_a(_strip_trailing_slashes(_convert_s_to_a(shift)));
  $config = _unique_paths(_expand_paths($config));
  $config;
}

#
# _pre_u_h
# params:
#   hashref - data.
# returns:
#   nothing important.
#
# does some action before update of a project is executed. data contains path
# (scalar) and tool_name (scalar) keys.
#
sub _pre_u_h
{
  my $ref_h_data = shift;
  my $path = $ref_h_data->{'path'};
  my $project;
  {
    my @dirs = File::Spec->splitdir($path);
    $project = $dirs[$#dirs];
  }
  print colored("updating " . $project . " using " . $ref_h_data->{'tool_name'} . ":", 'bold'), "\n";
}

#
# _pre_c_h
# params:
#   hashref - data.
# returns:
#   nothing important.
#
# does some action before command is executed. data contains command (scalar)
# key.
# 
sub _pre_c_h
{
  # it is empty - by default it will not print command names.
}

#
# _post_c_h
# params:
#   hashref - data.
# returns:
#   true to break command flow, false otherwise.
#
# does some action after command is executed. data contains command (scalar),
# ret_val (scalar) and output (scalar) keys.
#
sub _post_c_h
{
  my $ref_h_data = shift;
  my $ret = $ref_h_data->{'ret_val'};
  if ($ret)
  {
    my $command = $ref_h_data->{'command'};
    my $error_string;
    if ($ret == -1)
    {
      $error_string = "Command '" . $command . "' failed to execute:" . $!;
    }
    elsif (($ret & 127) == 2)
    {
      $error_string = "Command '" . $command . "' interrupted by user - interrupt again to abort.";
    }
    elsif ($ret & 127)
    {
      $error_string = "Command '" . $command . "' interrupted with signal " . ($ret & 127);
    }
    else
    {
      $error_string = "Command '" . $command . "' exited with value " . ($ret >> 8);
    }
    print colored ($error_string, 'bold'), "\n";
    if ($ret != -1 and ($ret & 127) == 2)
    {
      sleep(1);
    }
    $ret = 1;
  }
  $ret;
}

#
# _post_u_h
# params:
#   hashref - data.
# returns:
#   nothing important.
#
# does some action after update of a project is done. for now data contains no
# keys.
#
sub _post_u_h
{
  # empty, nothing to do here.
}

=head1 METHODS

=head2 new

C<new> creates new RepoUpdater. It takes hash of params, as follows:

=over

=item C<pre_u_h>:

Preupdate handler; defaults to internal one.

=item C<pre_c_h>:

Precommand handler; defaults to internal one.

=item C<post_c_h>:

Postcommand handler; defaults to internal one.

=item C<post_u_h>:

Postupdate handler; default to internal one.

=item C<config>:

Hashref containing configuration; defaults to one get from config files.

=item C<print_output>:

Whether to print commands' output (stdout and stderr combined); default to yes.

=back

 For more about handlers and their defaults, read C<HANDLERS>.
 For more about configuration, read C<CONFIGURATION>.

=cut

sub new
{
  my $type = shift;
  my $class = ref($type) || $type || "RepoUpdater";

  my %args = @_;
  %args = map {lc($_) => $args{$_}} keys %args;
  my $pre_u_handler = (exists($args{'pre_u_h'}) ? $args{'pre_u_h'} : \&_pre_u_h);
  my $pre_c_handler = (exists($args{'pre_c_h'}) ? $args{'pre_c_h'} : \&_pre_c_h);
  my $post_c_handler = (exists($args{'post_c_h'}) ? $args{'post_c_h'} : \&_post_c_h);
  my $post_u_handler = (exists($args{'post_u_h'}) ? $args{'post_u_h'} : \&_post_u_h);
  my $config_from_file = (exists($args{'config'}) ? 0 : 1);
  my $ref_h_repo_data = (exists($args{'config'}) ? $args{'config'} : Config::Auto::parse());
  unless ($config_from_file)
  {
    $ref_h_repo_data = $args{'config'};
    unless (exists($ref_h_repo_data->{'force-no-check'}) and $ref_h_repo_data->{'force-no-check'} == 1)
    {
      $ref_h_repo_data = _prepare($ref_h_repo_data);
    }
  }
  else
  {
    $ref_h_repo_data = _prepare(Config::Auto::parse());
  }
  my $p_c_o = (exists($args{'print_output'}) ? $args{'print_output'} : 1);
  my $self =
  {
    _repo_data => $ref_h_repo_data,
    _pre_update_handler => $pre_u_handler,
    _pre_command_handler => $pre_c_handler,
    _post_command_handler => $post_c_handler,
    _post_update_handler => $post_u_handler,
    _iter => 0,
    _print_to_stdout => $p_c_o
  };
  bless $self, $class;
}

=head2 repo_count

C<repo_count> returns number of repositories. It takes no parameters.

=cut

sub repo_count
{
  @_ == 1 or croak 'usage: $r_c = $ru->repo_count()';
  my $class = shift;
  my $r_c = @{$class->{'_repo_data'}{$p_opt}};
  $r_c;
}

=head2 updated_repo_count

C<updated_repo_count> returns number of updated repos. It takes no parameters.


=cut

sub updated_repo_count
{
  @_ == 1 or croak 'usage: $n_r_c = $ru->updated_repo_count()';
  my $class = shift;
  my $u_r_c = $class->{'_iter'};
  $u_r_c;
}

=head2 not_updated_repo_count

C<not_updated_repo_count> returns number of repos yet to be updated. It takes no
parameters.

=cut

sub not_updated_repo_count
{
  @_ == 1 or croak 'usage: $n_r_c = $ru->not_updated_repo_count()';
  my $class = shift;
  my $r_c = @{$class->{'_repo_data'}{$p_opt}};
  my $n_r_c = $r_c - $class->{'_iter'};
  $n_r_c;
}

=head2 rewind_one

C<rewind_one> causes last updated repo to be marked as a repo to be updated.

=cut

sub rewind_one
{
  @_ == 1 or croak 'usage: $ru->rewind_one()';
  my $class = shift;
  my $iter = $class->{'_iter'};
  if ($iter)
  {
    $class->{'_iter'} = $iter - 1;
  }
}

=head2 rewind

C<rewind> causes all repos to be marked as repos to be updated.

=cut

sub rewind
{
  @_ == 1 or croak 'usage: $ru->rewind()';
  my $class = shift;
  $class->{'_iter'} = 0;
}

=head2 update_one

C<update_one> performs an update of one repo. Putting this method in a loop from
0 to C<repo_count> will effect in updating all repositories. If all repos were
updated, then it starts from beginning. Takes no parameters.

=cut

sub update_one
{
  @_ == 1 or croak 'usage: $ru->update_one()';
  my $class = shift;
  my $iter = $class->{'_iter'};
  if ($iter == $class->repo_count())
  {
    $iter = 0;
  }
  $class->{'_iter'} = $iter + 1;
  my $path = $class->{'_repo_data'}{$p_opt}[$iter];
#  # eh, untainting?
#  $path =~ /^(.*)$/s;
#  $path = $1;
  foreach my $tool (@{$class->{'_repo_data'}{$t_opt}})
  {
    my $dir = File::Spec->catdir($path, $class->{'_repo_data'}{$tool . $d_suffix});
    if (-d $dir)
    {
      my $name = $class->{'_repo_data'}{$tool . $n_suffix};
      my $cwd = getcwd();
#      # eh, untainting?
#      $cwd =~ /^(.*)\z/s;
#      $cwd = $1;
      CORE::chdir $path;
      { $class->{'_pre_update_handler'}({path => $path, tool_name => $name}); }
      foreach my $command (@{$class->{'_repo_data'}{$tool . $c_suffix}})
      {
        { $class->{'_pre_command_handler'}({command => $command}); }
        my ($output, $ret) = ();
        if ($class->{'_print_to_stdout'})
        {
          $ENV{'PATH'} = '/bin:/usr/bin';
          delete @ENV{'IFS', 'CDPATH', 'ENV', 'BASH_ENV'};
          my ($tfd, $temp_name) = tempfile();
          $ret = system($command . " | tee " . $temp_name);
          $output = join "", <$tfd>;
          unlink0($tfd, $temp_name);
        }
        else
        {
          ($output, undef, $ret) = qxy($command);
        }
        my $skip;
        {  $skip = $class->{'_post_command_handler'}({output => $output, ret_val => $ret, command => $command}); }
        if ($skip)
        {
          last;
        }
      }
      { $class->{'_post_update_handler'}({}); }
      chdir $cwd;
      last;
    }
  }
}

=head2 update

C<update> performs an update of all repos given in configuration. It takes no
parameters.

=cut

sub update
{
  @_ == 1 or croak 'usage: $ru->update()';
  my $class = shift;
  while ($class->not_updated_repo_count())
  {
    $class->update_one();
  }
}

=head2 current_path

C<current_path> returns path to a repo that will be updated next.

=cut

sub current_path
{
  @_ == 1 or croak 'usage: $c_p = $ru->current_path()';
  my $class = shift;
  return $class->{'_repo_data'}{$p_opt}[$class->{'_iter'}];
}

=head2 all_paths

C<all_paths> returns arrayref of paths. Do not modify!

=cut

sub all_paths
{
  @_ == 1 or croak 'usage: $a_p = $ru->all_paths()';
  my $class = shift;
  return $class->{'_repo_data'}{$p_opt};
}

=head1 HANDLERS

=over 4

=item C<pre_u_h> - preupdate handler:

Reference to subroutine taking hash containing C<path> (scalar) and C<tool_name>
(scalar) keys. Its return value does not matter. This handler is executed before
updating a project.

Default preupdate handler prints C<updating $project using $tool_name>, where
C<project> is last directory name in C<path>. Needs C<Term::ANSIColor>.

=item C<pre_c_h> - precommand handler:

Reference to subroutine taking hash containing C<command> (scalar) key. Its
return value does not matter. This handler is executed before running a command,
so for one update it can be executed several times.

Default precommand handler does nothing.

=item C<post_c_h> - postcommand handler:

Reference to subroutine taking hash containing C<command> (scalar), C<output>
(scalar) and C<ret_val> (scalar) keys. Its return value does matter - return
true to stop executing commands for this update and go to next one or false to
continue. This handler is executed after calling every command, so it can be
executed several times.

Output can be whatever a C<command> prints, so expect also escape sequences.

Default handler analyzes C<ret_val>. If C<ret_val> is nonzero, then depending on
value of it, prints an error and returns true. If command was interrupted by
SIGINT (common by pressing CTRL+c) handler will sleep for a second just in case
user wanting to abort updating. Needs C<Term::ANSIColor>.

=item C<post_u_h> - postupdate handler:

Reference to subroutine taking nothing for now. Its return value does not
matter. Handler is executed when updating a project is finished.

Default handler does nothing.

=back

=head1 CONFIGURATION

=head2 Example configuration file:

Configuration file should be formatted, named and put into place to be foundable
and parsable by C<Config::Auto> module. The below format is recommended, because
other were not tested yet.

 paths = /home/user/projects/repos other_projects/other_repos
 tools = git hg cvs

 # git setup
 git-dir = .git
 git-name = git
 git-commands = "git pull"

 # mercurial setup
 hg-dir = .hg
 hg-name = mercurial
 hg-commands = "hg pull" "hg update"

 # CVS setup
 cvs-dir = CVS
 cvs-name = CVS
 cvs-commands = "cvs update -d"

=head2 Example configuration hashref:

If configuration hashref is passed to new, then it will be used as a base for
updating projects. Here structure of configuration hashref is described.

 my $config = {
               'paths' => ['/path1/repos' '/path2/repos'],
               'tools' => ['tool1' 'tool2'],
               'tool1-dir' => '.tool1',
               'tool1-name' => 'ToolOne',
               'tool1-commands' => ['tool1 pull' 'tool1 update' 'my-foo'],
               'tool2-dir' => '.tool2',
               'tool2-name' => 'ToolTwo',
               'tool2-commands' => ['tool2 ook' 'tool2 eek' 'my-bar'],
               'force-no-check' => 1
              };

Hashref can contain one additional key, C<force-no-check>. If you are really
really pretty sure, that your config hashref is 100% valid then define this key
with value 1. Other values or lack of this key mean that hashref needs to be
checked. Defining this key in configuration file means nothing.

=head2 Configuration explained:

=over

=item C<paths> - space-separated list of paths:

If path is relative, then it is converted to absolute with user's home directory
as a base, that is - C<other_projects/other_repos> will become
C</home/user/other_projects/other_repos>. If path contains spaces, put it in
double-quotes eg. C</path/with space/repo>. If path contains double-quotes,
escape them.

=item C<tools> - space separated list of tools:

They are used as a base for their specific options. They don't have to be real
names. C<superduperubertool> is also valid, provided that rest of key will have
appropriate names (C<superduperubertool-dir = .git>).

=item C<< E<lt>toolE<gt>-dir >> - name of a directory specific for a
E<lt>toolE<gt>:

Only one value is allowed.

=item C<< E<lt>toolE<gt>-name >> => name of a E<lt>toolE<gt>:

Only one value is allowed.

=item C<< E<lt>toolE<gt>-commands >> - list of space separated commands:

Commands to execute, when found a E<lt>toolE<gt>-dir in directory. Since most of
scm tools now use two part commands (hg pull, svn update), such have to be put
into double quotes.

=back

=head1 TODO

=over 4

=item Postupdate handler now takes no parameters:

I have to think what can be passed here.

=back

=head1 AUTHOR

Krzesimir Nowak, C<< <qdlacz at gmail.com> >>

=head1 BUGS

Please report bugs or other issues to E<lt>qdlacz at gmail.comE<gt>.


=head1 SUPPORT

You can find documentation for this module with the perldoc command.

=over

perldoc RepoUpdater

=back

=head1 COPYRIGHT & LICENSE

Copyright 2009 Krzesimir Nowak, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 SEE ALSO

Config::Auto

=cut

1; # End of RepoUpdater
