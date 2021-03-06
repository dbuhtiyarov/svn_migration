# iterate over mail archives, calling a function on each message.
#
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

package Mail::SpamAssassin::ArchiveIterator;

use strict;
use bytes;

use IO::Select;
use IO::Socket;
use Mail::SpamAssassin::Util;
use Mail::SpamAssassin::Constants qw(:sa);

use constant BIG_BYTES => 256*1024;	# 256k is a big email
use constant BIG_LINES => BIG_BYTES/65;	# 65 bytes/line is a good approximation

my $no = 1;

use vars qw {
  $MESSAGES
};

my @ISA = qw($MESSAGES);

###########################################################################

sub new {
  my $class = shift;
  $class = ref($class) || $class;

  my $self = shift;
  if (!defined $self) { $self = { }; }
  bless ($self, $class);

  $self->{s} = { };		# spam, of course
  $self->{h} = { };		# ham, as if you couldn't guess

  $self;
}

###########################################################################

sub set_functions {
  my ($self, $wanted, $result) = @_;
  $self->{wanted_sub} = $wanted;
  $self->{result_sub} = $result;
}

###########################################################################

sub run {
  my ($self, @targets) = @_;

  if (!defined $self->{wanted_sub}) {
    die "set_functions never called";
  }

  # non-forking model (generally sa-learn), everything in a single process
  if ($self->{opt_j} == 0) {
    my $message;
    my $class;
    my $result;
    my $messages;

    # message-array
    ($MESSAGES, $messages) = $self->message_array(\@targets);

    while ($message = shift @{$messages}) {
      my ($class, undef, $date) = index_unpack($message);
      $result = $self->run_message($message);
      &{$self->{result_sub}}($class, $result, $date) if $result;
    }
  }
  # forking model (generally mass-check), avoid extended memory usage
  else {
    my $tmpf;
    ($tmpf, $self->{messageh}) = Mail::SpamAssassin::Util::secure_tmpfile();
    unlink $tmpf;
    undef $tmpf;

    # forked child process scans messages
    if ($tmpf = fork()) {
      # parent
      waitpid($tmpf, 0);
    }
    elsif (defined $tmpf) {
      # child
      $self->message_array(\@targets, $self->{messageh});
      exit;
    }
    else {
      die "cannot fork: $!";
    }

    # we now have a temp file with the messages to process
    seek ($self->{messageh}, 0, 0);
    $MESSAGES = $self->next_message();

    # only do 1 process, message list in a temp file, no restarting
    if ($self->{opt_j} == 1 && !defined $self->{opt_restart}) {
      my $message;
      my $class;
      my $result;
      my $messages;
      my $total_count = 0;

      while (($MESSAGES > $total_count) && ($message = $self->next_message()))
      {
        my ($class, undef, $date) = index_unpack($message);
        $result = $self->run_message($message);
        &{$self->{result_sub}}($class, $result, $date) if $result;
	$total_count++;
      }
    }
    # more than one process or one process with restarts
    else {
      my $select = IO::Select->new();

      my $total_count = 0;
      my $needs_restart = 0;
      my @child = ();
      my @pid = ();
      my $messages;

      # start children processes
      $self->start_children($self->{opt_j}, \@child, \@pid, $select);

      # feed childen, make them work for it, repeat
      while ($select->count()) {
        foreach my $socket ($select->can_read()) {
	  my $result = '';
	  my $line;
	  while ($line = readline $socket) {
	    if ($line =~ /^RESULT (.+)$/) {
	      my ($class,$type,$date) = index_unpack($1);
	      #warn ">> RESULT: $class, $type, $date\n";

	      if (defined $self->{opt_restart} &&
		  ($total_count % $self->{opt_restart}) == 0)
	      {
	        $needs_restart = 1;
	      }

	      # if messages remain, and we don't need to restart, send message
	      if (($MESSAGES > $total_count) && !$needs_restart) {
	        print { $socket } $self->next_message() . "\n";
	        $total_count++;
	        #warn ">> recv: $MESSAGES $total_count\n";
	      }
	      else {
	        # stop listening on this child since we're done with it
	        #warn ">> removeresult: $needs_restart $MESSAGES $total_count\n";
	        $select->remove($socket);
	      }

	      # deal with the result we received
	      if ($result) {
	        chop $result;	# need to chop the \n before RESULT
	        &{$self->{result_sub}}($class, $result, $date);
	      }

	      last;	# this will avoid the read for this client
	    }
	    elsif ($line eq "START\n") {
	      if ($MESSAGES > $total_count) {
	        # we still have messages, send one to child
	        print { $socket } $self->next_message() . "\n";
	        $total_count++;
	        #warn ">> new: $MESSAGES $total_count\n";
	      }
	      else {
	        # no more messages, so stop listening on this child
	        #warn ">> removestart: $needs_restart $MESSAGES $total_count\n";
	        $select->remove($socket);
	      }

	      last;	# this will avoid the read for this client
	    }
	    else {
	      # result line, remember it
	      $result .= $line;
	    }
	  }

          # some error happened during the read!
          if (!defined $line || !$line) {
            $needs_restart = 1;
            warn "readline failed, attempting to recover\n";
            $select->remove($socket);
          }
        }

        #warn ">> out of loop, $MESSAGES $total_count $needs_restart ".$select->count()."\n";

        # If there are still messages to process, and we need to restart
        # the children, and all of the children are idle, let's go ahead.
        if ($needs_restart && $select->count == 0 && $MESSAGES > $total_count)
	{
	  $needs_restart = 0;

	  #warn "debug: Needs restart, $MESSAGES total, $total_count done.\n";
	  $self->reap_children($self->{opt_j}, \@child, \@pid);
	  @child=();
	  @pid=();
	  $self->start_children($self->{opt_j}, \@child, \@pid, $select);
        }
      }

      # reap children
      $self->reap_children($self->{opt_j}, \@child, \@pid);
    }

    # close tempfile so it will be unlinked
    close($self->{messageh});
  }
}

############################################################################

sub message_array {
  my ($self, $targets, $fh) = @_;

  foreach my $target (@${targets}) {
    my ($class, $format, $rawloc) = split(/:/, $target, 3);

    # use ham by default, things like "spamassassin" can't specify the type
    $class = substr($class, 0, 1) || 'h';

    my @locations = $self->fix_globs($rawloc);

    foreach my $location (@locations) {
      my $method;

      if ($format eq 'detect') {
	# detect the format
	if ($location eq '-' || !(-d $location)) {
	  # stdin is considered a file if not passed as mbox
	  $method = \&scan_file;
	}
	else {
	  # it's a directory
	  $method = \&scan_directory;
	}
      }
      else {
	if ($format eq "dir") {
	  $method = \&scan_directory;
	}
	elsif ($format eq "file") {
	  $method = \&scan_file;
	}
	elsif ($format eq "mbox") {
	  $method = \&scan_mailbox;
        }
	elsif ($format eq "mbx") {
	  $method = \&scan_mbx;
	}
      }

      if(defined($method)) {
	&{$method}($self, $class, $location);
      }
      else {
	warn "format $format unknown!";
      }
    }
  }

  my @messages;
  if ($self->{opt_n}) {
    my %both = (%{ $self->{s} }, %{$self->{h}});
    undef $self->{s};
    undef $self->{h};
    @messages = sort({ $both{$a} <=> $both{$b} } keys %both);
    splice(@messages, $self->{opt_head}) if $self->{opt_head};
    splice(@messages, 0, -$self->{opt_tail}) if $self->{opt_tail};
  }
  else {
    my @s = sort({ $self->{s}->{$a} <=> $self->{s}->{$b} } keys %{$self->{s}});
    undef $self->{s};
    my @h = sort({ $self->{h}->{$a} <=> $self->{h}->{$b} } keys %{$self->{h}});
    undef $self->{h};
    splice(@s, $self->{opt_head}) if $self->{opt_head};
    splice(@s, 0, -$self->{opt_tail}) if $self->{opt_tail};
    splice(@h, $self->{opt_head}) if $self->{opt_head};
    splice(@h, 0, -$self->{opt_tail}) if $self->{opt_tail};
    while (@s && @h) {
      push @messages, (shift @s);
      push @messages, (shift @h);
    }
    push @messages, (splice @s), (splice @h);
  }

  if (defined $fh) {
    print { $fh } map { "$_\n" } scalar(@messages), @messages;
    return;
  }

  return scalar(@messages), \@messages;
}

sub next_message {
  my ($self) = @_;
  my $line = readline $self->{messageh};
  chomp $line if defined $line;
  return $line;
}

sub start_children {
  my ($self, $count, $child, $pid, $socket) = @_;

  my $io = IO::Socket->new();
  my $parent;

  # create children
  for (my $i = 0; $i < $count; $i++) {
    ($child->[$i],$parent) = $io->socketpair(AF_UNIX,SOCK_STREAM,PF_UNSPEC)
	or die "socketpair failed: $!";
    if ($pid->[$i] = fork) {
      close $parent;

      # disable caching for parent<->child relations
      my ($old) = select($child->[$i]);
      $|++;
      select($old);

      $socket->add($child->[$i]);
      #warn "debug: starting new child $i (pid ",$pid->[$i],")\n";
      next;
    }
    elsif (defined $pid->[$i]) {
      my $result;
      my $line;

      close $self->{messageh} if defined $self->{messageh};

      close $child->[$i];
      select($parent);
      $| = 1;	# print to parent by default, turn off buffering
      print "START\n";
      while ($line = readline $parent) {
	chomp $line;
	if ($line eq "exit") {
	  print "END\n";
	  close $parent;
	  exit;
	}
	$result = $self->run_message($line);
	$result ||= '';
	print "$result\nRESULT $line\n";
      }
      exit;
    }
    else {
      die "cannot fork: $!";
    }
  }
}

sub reap_children {
  my ($self, $count, $socket, $pid) = @_;

  # If the child died, sending it the exit will generate a SIGPIPE, but we
  # don't really care since the readline will go undef (which is fine),
  # then we do the waitpid which will finish it off.  So we end up in the
  # right state, in theory.
  local $SIG{'PIPE'} = 'IGNORE';

  for (my $i = 0; $i < $count; $i++) {
    #warn "debug: killing child $i (pid ",$pid->[$i],")\n";
    print { $socket->[$i] } "exit\n"; # tell the child to die.
    my $line = readline $socket->[$i]; # read its END statement.
    close $socket->[$i];
    waitpid($pid->[$i], 0); # wait for the signal ...
  }
}

sub mail_open {
  my ($file) = @_;

  my $expr;
  if ($file =~ /\.gz$/) {
    $expr = "gunzip -cd $file |";
  }
  elsif ($file =~ /\.bz2$/) {
    $expr = "bzip2 -cd $file |";
  }
  else {
    $expr = "$file";
  }
  if (!open (INPUT, $expr)) {
    warn "Unable to open $file: $!\n";
    return 0;
  }
  return 1;
}

############################################################################

sub message_is_useful_by_date  {
  my ($self, $date) = @_;

  return 0 unless $date;	# undef or 0 date = unusable

  if (!$self->{opt_after} && !$self->{opt_before}) {
    # Not using the feature
    return 1;
  }
  elsif (!$self->{opt_before}) {
    # Just case about after
    return $date > $self->{opt_after};
  }
  else {
    return (($date < $self->{opt_before}) && ($date > $self->{opt_after}));
  }
}

############################################################################

sub index_pack {
  return join("\000", @_);
}

sub index_unpack {
  return split(/\000/, $_[0]);
}

sub scan_directory {
  my ($self, $class, $folder) = @_;

  my @files;

  opendir(DIR, $folder) || die "Can't open '$folder' dir: $!";
  if (-f "$folder/cyrus.header") {
    # cyrus metadata: http://unix.lsa.umich.edu/docs/imap/imap-lsa-srv_3.html
    @files = grep { /^\S+$/ && !/^cyrus\.(?:index|header|cache|seen)/ }
			readdir(DIR);
  }
  else {
    # ignore ,234 (deleted or refiled messages) and MH metadata dotfiles
    @files = grep { !/^[,.]/ } readdir(DIR);
  }
  closedir(DIR);

  @files = grep { -f } map { "$folder/$_" } @files;

  foreach my $mail (@files) {
    if ($self->{opt_n}) {
      $self->{$class}->{index_pack($class, "f", $no, $mail)} = $no;
      $no++;
      next;
    }
    my $header;
    mail_open($mail) or next;
    while (<INPUT>) {
      last if /^$/;
      $header .= $_;
    }
    close(INPUT);
    my $date = Mail::SpamAssassin::Util::receive_date($header);
    next if !$self->message_is_useful_by_date($date);
    $self->{$class}->{index_pack($class, "f", $date, $mail)} = $date;
  }
}

sub scan_file {
  my ($self, $class, $mail) = @_;

  if ($self->{opt_n}) {
    $self->{$class}->{index_pack($class, "f", $no, $mail)} = $no;
    $no++;
    return;
  }
  my $header;
  mail_open($mail) or return;
  while (<INPUT>) {
    last if /^$/;
    $header .= $_;
  }
  close(INPUT);
  my $date = Mail::SpamAssassin::Util::receive_date($header);
  return if !$self->message_is_useful_by_date($date);
  $self->{$class}->{index_pack($class, "f", $date, $mail)} = $date;
}

sub scan_mailbox {
  my ($self, $class, $folder) = @_;
  my @files;

  if ($folder ne '-' && -d $folder) {
    # passed a directory of mboxes
    $folder =~ s/\/\s*$//; #Remove trailing slash, if there
    opendir(DIR, $folder) || die "Can't open '$folder' dir: $!";
    while($_ = readdir(DIR)) {
      if(/^[^\.]\S*$/ && ! -d "$folder/$_") {
	push(@files, "$folder/$_");
      }
    }
    closedir(DIR);
  }
  else {
    push(@files, $folder);
  }

  foreach my $file (@files) {
    if ($file =~ /\.(?:gz|bz2)$/) {
      die "compressed mbox folders are not supported at this time\n";
    }

    mail_open($file) or return;
    
    my $start = 0;		# start of a message
    my $where = 0;		# current byte offset
    my $first = '';		# first line of message
    my $header = '';		# header text
    my $in_header = 0;		# are in we a header?
    while (!eof INPUT) {
      my $offset = $start;	# byte offset of this message
      my $header = $first;	# remember first line
      while (<INPUT>) {
	if ($in_header) {
	  if (/^$/) {
	    $in_header = 0;
	  }
	  else {
	    $header .= $_;
	  }
	}
	if (substr($_,0,5) eq "From ") {
	  $in_header = 1;
	  $first = $_;
	  $start = $where;
	  $where = tell INPUT;
	  last;
	}
	$where = tell INPUT;
      }
      if ($header) {
	my $t;
	if ($self->{opt_n}) {
	  $t = $no++;
	}
	else {
	  $t = Mail::SpamAssassin::Util::receive_date($header);
	  next if !$self->message_is_useful_by_date($t);
	}
	$self->{$class}->{index_pack($class, "m", $t, "$file.$offset")} = $t;
      }
    }
    close INPUT;
  }
}

sub scan_mbx {
    my ($self, $class, $folder) = @_ ;
    my (@files, $fp) ;
    
    if ($folder ne '-' && -d $folder) {
	# got passed a directory full of mbx folders.
	$folder =~ s/\/\s*$//; # remove trailing slash, if there is one
	opendir(DIR, $folder) || die "Can't open '$folder' dir: $!" ;
	while($_ = readdir(DIR)) {
	    if(/^[^\.]\S*$/ && ! -d "$folder/$_") {
		push(@files, "$folder/$_");
	    }
	}
	closedir(DIR);
    } else {
	push(@files, $folder) ;
    }
    
    foreach my $file (@files) {
	if ($folder =~ /\.(?:gz|bz2)$/) {
	    die "compressed mbx folders are not supported at this time\n" ;
	}
	mail_open($file) or return ;

	# check the mailbox is in mbx format
	$fp = <INPUT> ;
	if ($fp !~ /\*mbx\*/) {
	    die "Error, mailbox not in mbx format!\n" ;
	}
	
	# skip mbx headers to the first email...
	seek(INPUT, 2048, 0) ;

        my $sep = MBX_SEPARATOR;
    
	while (<INPUT>) {
	    if ($_ =~ /$sep/) {
		my $offset = tell INPUT ;
		my $size = $2 ;

		# gather up the headers...
		my $header = '' ;
		while (<INPUT>) {
		    last if (/^$/) ;
		    $header .= $_ ;
		}

		my $t;
		if ($self->{opt_n}) {
		    $t = $no++;
		} else {
		    $t = Mail::SpamAssassin::Util::receive_date($header);
		    next if !$self->message_is_useful_by_date($t);
		}
		$self->{$class}->{index_pack($class, "b", $t, "$file.$offset")} = $t;
		seek(INPUT, $offset + $size, 0) ;
	    } else {
		die "Error, failure to read message body!\n" ;
	    }
	}
	close INPUT;
    }
}

############################################################################

sub run_message {
  my ($self, $msg) = @_;

  my ($class, $format, $date, $mail) = index_unpack($msg);

  if ($format eq "f") {
    return $self->run_file($class, $mail, $date);
  }
  elsif ($format eq "m") {
    return $self->run_mailbox($class, $mail, $date);
  }
  elsif ($format eq "b") {
    return $self->run_mbx($class, $mail, $date);
  }
}

sub run_file {
  my ($self, $class, $where, $date) = @_;

  mail_open($where) or return;
  # skip too-big mails
  if (! $self->{opt_all} && -s INPUT > BIG_BYTES) {
    close INPUT;
    return;
  }
  my @msg = (<INPUT>);
  close INPUT;

  &{$self->{wanted_sub}}($class, $where, $date, \@msg);
}

sub run_mailbox {
  my ($self, $class, $where, $date) = @_;

  my ($file, $offset) = ($where =~ m/(.*)\.(\d+)$/);
  my @msg;
  mail_open($file) or return;
  seek(INPUT,$offset,0);
  my $past = 0;
  while (<INPUT>) {
    if ($past) {
      last if substr($_,0,5) eq "From ";
    }
    else {
      $past = 1;
    }
    # skip too-big mails
    if (! $self->{opt_all} && @msg > BIG_LINES) {
      close INPUT;
      return;
    }
    push (@msg, $_);
  }
  close INPUT;
  &{$self->{wanted_sub}}($class, $where, $date, \@msg);
}

sub run_mbx {
    my ($self, $class, $where, $date) = @_ ;

    my ($file, $offset) = ($where =~ m/(.*)\.(\d+)$/) ;
    my @msg ;

    mail_open($file) or return ;
    seek(INPUT, $offset, 0) ;
    
    while (<INPUT>) {
	last if ($_ =~ MBX_SEPARATOR) ;
	
	# skip mails that are too big
	if (! $self->{opt_all} && @msg > BIG_LINES) {
	    close INPUT ;
	    return ;
	}
	push (@msg, $_) ;
    }
    close INPUT ;
    &{$self->{wanted_sub}}($class, $where, $date, \@msg) ;
}

############################################################################

sub fix_globs {
  my ($self, $path) = @_;

  # replace leading tilde with home dir: ~/abc => /home/jm/abc
  $path =~ s/^~/$ENV{'HOME'}/;

  # protect/escape spaces: ./Mail/My Letters => ./Mail/My\ Letters
  $path =~ s/([^\\])(\s)/$1\\$2/g;

  my @paths;

  # apply csh-style globs: ./corpus/*.mbox => er, you know what it does ;)
  @paths = glob $path;
  return @paths;
}

############################################################################

1;
