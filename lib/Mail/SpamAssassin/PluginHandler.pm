# <@LICENSE>
# Copyright 2004 Apache Software Foundation
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# </@LICENSE>

=head1 NAME

Mail::SpamAssassin::PluginHandler - SpamAssassin plugin handler

=cut

package Mail::SpamAssassin::PluginHandler;
use Mail::SpamAssassin;
use Mail::SpamAssassin::Plugin;

use strict;
use bytes;
use File::Spec;

use vars qw{
  @ISA $VERSION
};

@ISA = qw();

$VERSION = 'bogus';     # avoid CPAN.pm picking up version strings later

###########################################################################

sub new {
  my $class = shift;
  my $main = shift;
  $class = ref($class) || $class;
  my $self = {
    plugins		=> [ ],
    cbs 		=> { },
    main		=> $main
  };
  bless ($self, $class);
  $self;
}

###########################################################################

sub load_plugin {
  my ($self, $package, $path) = @_;

  my $ret;
  if ($path) {
    dbg ("plugin: loading $package from $path");
    $ret = do $path;
  }
  else {
    dbg ("plugin: loading $package from \@INC");
    $ret = eval qq{ require $package; };
    $path = "(from \@INC)";
  }

  if (!$ret) {
    if ($@) { warn "failed to parse plugin $path: $@\n"; }
    elsif ($!) { warn "failed to load plugin $path: $!\n"; }
  }

  my $plugin = eval $package.q{->new ($self->{main}); };

  if ($@ || !$plugin) { warn "failed to create instance of plugin $package: $@\n"; }

  # Don't load the same plugin twice!
  foreach my $old_plugin (@{$self->{plugins}}) {
    if (ref($old_plugin) eq ref($plugin)) {
      warn "Plugin " . ref($old_plugin) . " already registered\n";
      dbg("plugin: did not register $plugin, already registered");
      return;
    }
  }

  if ($plugin) {
    $self->{main}->{plugins}->register_plugin ($plugin);
    $self->{main}->{conf}->load_plugin_succeeded ($plugin, $package, $path);
  }
}

sub register_plugin {
  my ($self, $plugin) = @_;
  $plugin->{main} = $self->{main};
  push (@{$self->{plugins}}, $plugin);
  dbg ("plugin: registered $plugin");
}

###########################################################################

sub callback {
  my $self = shift;
  my $subname = shift;
  my ($ret, $overallret);

  # have we set up the cache entry for this callback type?
  if (!exists $self->{cbs}->{$subname}) {
    # nope.  run through all registered plugins and see which ones
    # implement this type of callback
    my @subs = ();
    foreach my $plugin (sort @{$self->{plugins}}) {
      my $methodref = $plugin->can ($subname);
      if (defined $methodref) {
        push (@subs, [ $plugin, $methodref ]);
        dbg ("plugin: ${plugin} implements '$subname'");
      }
    }
    $self->{cbs}->{$subname} = \@subs;
  }

  foreach my $cbpair (@{$self->{cbs}->{$subname}}) {
    my ($plugin, $methodref) = @$cbpair;

    $plugin->{_inhibit_further_callbacks} = 0;

    eval {
      $ret = &$methodref ($plugin, @_);
    };
    if ($ret) {
      #dbg ("plugin: ${plugin}->${methodref} => $ret");
      $overallret = $ret;

      if ($ret == $Mail::SpamAssassin::Plugin::INHIBIT_CALLBACKS) {
        $plugin->{_inhibit_further_callbacks} = 1;
        $ret = 1;
      }
    }

    if ($plugin->{_inhibit_further_callbacks}) {
      dbg ("plugin: $plugin inhibited further callbacks");
      last;
    }
  }

  $overallret ||= $ret;
  return $overallret;
}

###########################################################################

sub finish {
  my $self = shift;
  delete $self->{cbs};
  foreach my $plugin (@{$self->{plugins}}) {
    $plugin->finish();
    delete $plugin->{main};
  }
  delete $self->{plugins};
  delete $self->{main};
}

###########################################################################

sub dbg { Mail::SpamAssassin::dbg (@_); }

1;
