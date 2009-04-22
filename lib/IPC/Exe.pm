package IPC::Exe;

use 5.006_000;

use warnings;
use strict;

# XXX: be quiet about "Attempt to free unreferenced scalar" on Win32
no warnings qw(internal);

BEGIN {
    require Exporter;
    *import = \&Exporter::import; # just inherit import() only

    our $VERSION   = 1.005;
    our @EXPORT_OK = qw(&exe &bg);
}

use POSIX qw(WNOHANG);
use File::Spec;
use Time::HiRes qw(usleep);

# define null device
my $DEVNULL = File::Spec->devnull();

# define non-Unix platforms
my $non_unix = ($^O =~ /^(?:MSWin32|os2)$/);

# bg() fallback to forked child/parent process to ensure execution
our $bg_fallback = 0;

# check ref type
sub _is_hash { ref($_[0]) && eval { %{ $_[0] } or 1 } }
sub _is_code { UNIVERSAL::isa($_[0], "CODE") }
sub _is_fh   { eval { defined(fileno($_[0])) } }

# closure allows exe() to do its magical arguments arrangement
sub exe {
    # return empty list if no arguments
    return () if @_ == 0;

    # return only single CODE argument
    #   e.g. exe sub { .. };
    #          returns
    #        sub { .. }
    my ($code) = @_;
    if (@_ == 1 && _is_code($code))
    {
        return $code;
    }

    # otherwise return closure
    my @args = @_;
    return sub {
        my @_closure = @_;
        _exe(\@_closure, @args);
    }
}
sub _exe {
    # obtain reference to arguments passed to closure
    my $_closure = shift();

    # merge options hash reference, if available
    my %opt = (
        stdin      => 0,
        stdout     => 0,
        stderr     => 0,
        autoflush  => 1,
        binmode_io => undef,
        exec       => 0,
    );
    if (_is_hash($_[0]))
    {
        @opt{keys %{ $_[0] }} = values %{ $_[0] };
        shift();
    }

    # propagate $opt{binmode_io} to set binmode down chain of executions
    my $binmode_io = defined($opt{binmode_io})
                         ? $opt{binmode_io}
                         : $IPC::Exe::_binmode_io;
    local $IPC::Exe::_binmode_io = $binmode_io;

    # non-Unix: decide whether to exec() or system()
    # propagate $opt{stdin} to cause exec down chain of executions
    my $exec = $opt{exec} || $opt{stdin} || $IPC::Exe::_stdin;
    my $stdin = $IPC::Exe::_stdin || $opt{stdin};
    local $IPC::Exe::_stdin = $stdin;

    # setup input filehandle to write to STDIN
    my ($FOR_STDIN, $TO_STDIN);
    if ($opt{stdin})
    {
        pipe($FOR_STDIN, $TO_STDIN)
            or warn("IPC::Exe::exe() cannot create pipe to STDIN\n  $!")
            and return ();

        # make filehandle hot
        select((select($TO_STDIN), $| = 1)[0]) if $opt{autoflush};
    }

    # setup output filehandle to read from STDERR
    my ($FROM_STDERR, $BY_STDERR);
    if ($opt{stderr})
    {
        pipe($FROM_STDERR, $BY_STDERR)
            or warn("IPC::Exe::exe() cannot create pipe from STDERR\n  $!")
            and return ();
    }

    # obtain CODE references, if available, for READER & PREEXEC subroutines
    my $Preexec = shift() if _is_code($_[0]);
    my $Reader  =   pop() if _is_code($_[$#_]);

    # as a precaution, do not continue if no PREEXEC or LIST found
    return () unless defined($Preexec) || @_;

    # dup(2) stdin to be restored later
    my $ORIGSTDIN;
    open($ORIGSTDIN, "<&" . fileno(*STDIN))
        or warn("IPC::Exe::exe() cannot dup(2) STDIN\n  $!")
        and return ();

    # safe pipe open to forked child connected to opened filehandle
    my ($gotchild, $EXE_READ, $EXE_READY, $EXE_GO);
    my $defined_child = defined(
        $gotchild = _pipe_from_fork($EXE_READ, $EXE_READY, $EXE_GO)
    );

    # check if fork was successful
    unless ($defined_child)
    {
        warn("IPC::Exe::exe() cannot fork child\n  $!") and return ();
    }

    # parent reads stdout of child process
    if ($gotchild)
    {
        # close unneeded filehandles
        close($FOR_STDIN) if $FOR_STDIN;
        close($BY_STDERR) if $BY_STDERR;

        # set binmode if required
        if (defined($IPC::Exe::_binmode_io)
                 && $IPC::Exe::_binmode_io =~ /^:/)
        {
            my $layer = $IPC::Exe::_binmode_io;

            if ($opt{stdin})
            {
                binmode($TO_STDIN, $layer) or die(<<"EOT" . "  $!");
IPC::Exe::exe() cannot set binmode STDIN_WRITEHANDLE for layer "$layer"
EOT
            }

            binmode($EXE_READ, $layer) or die(<<"EOT" . "  $!");
IPC::Exe::exe() cannot set binmode STDOUT_READHANDLE for layer "$layer"
EOT
        }

        # temporarily replace stdin
        $IPC::Exe::_stdin
            ? open(*STDIN, "<&=" . fileno($EXE_READ))
            : open(*STDIN, "<&"  . fileno($EXE_READ))
                or die("IPC::Exe::exe() cannot replace STDIN\n  $!");

        # create package-scope $IPC::Exe::PIPE
        local our $PIPE = $EXE_READ;

        # only return child PID if exec was successful (i.e. not a bad command)
        my $ret_pid = 1;

        # non-Unix: shamefully fake $PIPE so that close($IPC::Exe::PIPE) will work
        if ($non_unix)
        {
            my $exit = readline($EXE_READY);
            close($EXE_READY);

            if (defined($exit))
            {
                # check if child "process" failed exec
                if ($exit == -1 || $exit == 255 << 8)
                {
                    $ret_pid = 0;
                    $exit = 255;
                }
                else
                {
                    $exit >>= 8;
                }
            }
            else
            {
                $exit = 0;
            }

            my $FAKE;
            open($FAKE, "-|", "$^X -e \"exit $exit\"")
                or die("IPC::Exe::exe() cannot fake \$IPC::Exe::PIPE\n  $!");

            $PIPE = $FAKE;
        }

        # call READER subroutine
        my @ret;
        if ($Reader)
        {
            # non-Unix: reset to default $IPC::Exe::_preexec_wait time
            local $IPC::Exe::_preexec_wait;

            { @ret = $Reader->(@_) }
        }
        else
        {
            unless ($opt{stdout})
            {
                # if undefined, just print stdin
                print while <$EXE_READ>;
                close($PIPE);
                $ret[0] = $?; # return exit status of previous pipe process
                $ret[0] = -1 unless $ret_pid; # non-Unix: failed exec
            }
        }

        # restore stdin
        open(*STDIN, "<&" . fileno($ORIGSTDIN))
            or die("IPC::Exe::exe() cannot restore STDIN\n  $!");

        # child PID is undef if exec failed
        my $reap = waitpid($gotchild, WNOHANG);
        #print STDERR "reap> $gotchild : $reap | $?\n";

        # reading from failed exec
        unless ($non_unix && !$exec)
        {
            $ret_pid = !(($reap == $gotchild && $? == 255 << 8)
                      || (!$Reader && !$opt{stdout}
                          && $reap == -1 && $? == -1
                          && $ret[0] == 255 << 8
                          && ($ret[0] = -1)));
        }

        # writing to failed exec
        if ($Reader && @ret && $reap == $gotchild && $? == -1)
        {
            $ret[0] = undef;
        }

        # collect child PIDs & filehandle(s)
        unshift(@ret,
            $ret_pid     ? $gotchild : undef,
            $opt{stdin}  ? $TO_STDIN    : (),
            $opt{stdout} ? $EXE_READ    : (),
            $opt{stderr} ? $FROM_STDERR : (),
        );

        return @ret[0 .. $#ret]; # return LIST instead of ARRAY
    }
    else # child performs exec()
    {
        # close unneeded filehandles
        close($TO_STDIN)    if $TO_STDIN;
        close($FROM_STDERR) if $FROM_STDERR;

        # disassociate any ties with parent
        untie(*STDIN);
        untie(*STDOUT);
        untie(*STDERR);

        # change STDIN if input filehandle was required
        if ($FOR_STDIN)
        {
            open(*STDIN, "<&" . fileno($FOR_STDIN))
                or die("IPC::Exe::exe() cannot change STDIN\n  $!");
        }

        # collect STDERR if error filehandle was required
        if ($BY_STDERR)
        {
            open(*STDERR, ">&" . fileno($BY_STDERR))
                or die("IPC::Exe::exe() cannot collect STDERR\n  $!");
        }

        # set binmode if required
        if (defined($IPC::Exe::_binmode_io)
                 && $IPC::Exe::_binmode_io =~ /^:/)
        {
            my $layer = $IPC::Exe::_binmode_io;

            binmode(*STDIN, $layer) and binmode(*STDOUT, $layer)
                or die(<<"EOT" . "  $!");
IPC::Exe::exe() cannot set binmode STDIN and STDOUT for layer "$layer"
EOT
        }

        # call PREEXEC subroutine if defined
        my @FHop;
        if ($Preexec)
        {
            { @FHop = $Preexec->(@{ $_closure }) }
        }

        # only exec() LIST if defined
        unless (@_)
        {
            # non-Unix: signal parent "process" to restore filehandles
            if ($non_unix && _is_fh($EXE_GO))
            {
                # pass 0 status back to parent
                print $EXE_GO "exe_no_exec\n0";
                close($EXE_GO);
            }

            exit(0);
        }

        # perform redirections
        for (@FHop)
        {
            next unless defined() && !ref();

            # silence stderr
            /^\s*2>\s*(?:null|#)\s*$/  and open(*STDERR, ">", $DEVNULL)
            || die(<<"EOT" . "  $!");
IPC::Exe::exe() cannot silence STDERR (does $DEVNULL exist?)
EOT

            # silence stdout
            /^\s*1?>\s*(?:null|#)\s*$/ and open(*STDOUT, ">", $DEVNULL)
            || die(<<"EOT" . "  $!");
IPC::Exe::exe() cannot silence STDOUT (does $DEVNULL exist?)
EOT

            # redirect stderr to stdout
            /^\s*2>&\s*1\s*$/          and open(*STDERR, ">&" . fileno(*STDOUT))
            || die(<<"EOT" . "  $!");
IPC::Exe::exe() cannot redirect STDERR to STDOUT
EOT

            # redirect stdout to stderr
            /^\s*1?>&\s*2\s*$/         and open(*STDOUT, ">&" . fileno(*STDERR))
            || die(<<"EOT" . "  $!");
IPC::Exe::exe() cannot redirect STDOUT to STDERR
EOT

            # swap stdout and stderr
            if (/^\s*(?:1><2|2><1)\s*$/)
            {
                my $SWAP;
                open($SWAP, ">&" . fileno(*STDOUT))
                    and open(*STDOUT, ">&" . fileno(*STDERR))
                    and open(*STDERR, ">&" . fileno($SWAP))
                    or die(<<"EOT" . "  $!");
IPC::Exe::exe() cannot swap STDOUT and STDERR
EOT
            }

            # set binmode
            if (/^\s*([012])(:.*)$/)
            {
                my $fh_name = qw(STDIN STDOUT STDERR)[$1];
                my $layer = $2;
                $layer = ":raw" if $layer eq ":";

                binmode((*STDIN, *STDOUT, *STDERR)[$1], $layer)
                    or die(<<"EOT" . "  $!");
IPC::Exe::exe() cannot set binmode $fh_name for layer "$layer"
EOT
            }
        }

        local $" = " ";

        # non-Unix: escape command so that it feels Unix-like
        my @cmd = $non_unix
                      ? map {
                            (my $x = $_) =~ s/([\\"])/\\$1/g;
                            qq("$x");
                        } @_
                      : @_;

        if ($non_unix && !$exec)
        {
            # use system() instead to get exit status
            my $exit = system { $cmd[0] } @cmd;
            warn("IPC::Exe::exe() failed to exec: @cmd\n")
                if $exit == -1 || $exit == 255 << 8;

            # non-Unix: signal parent "process" to restore filehandles
            if (_is_fh($EXE_GO))
            {
                # pass $exit status back to parent
                print $EXE_GO "exe_with_system\n$exit";
                close($EXE_GO);
            }

            exit $exit >> 8;
        }
        else
        {
            # non-Unix: signal parent "process" to restore filehandles
            if ($non_unix && _is_fh($EXE_GO))
            {
                # pass 0 status back to parent
                print $EXE_GO "exe_with_exec\n0";
                close($EXE_GO);
            }

            # assume exit status 255 indicates failed exec
            exec { $cmd[0] } @cmd
                or die(($! = -1, "IPC::Exe::exe() failed to exec: @cmd\n")[1]);
        }
    }
}

# closure allows bg() to do its magical call placement
sub bg {
    # return empty list if no arguments
    return () if @_ == 0;

    # only consider first 2 arguments
    my @args = @_[0 .. 1];
    return sub {
        my @_closure = @_;
        _bg(\@_closure, @args);
    }
}
sub _bg {
    # obtain reference to arguments passed to closure
    my $_closure = shift();

    # merge options hash reference, if available
    my %opt = (
        wait => 2,
    );
    if (_is_hash($_[0]))
    {
        @opt{keys %{ $_[0] }} = values %{ $_[0] };
        shift();
    }

    # obtain CODE reference for BACKGROUND subroutine
    my $Background = shift() if _is_code($_[0]);

    # do not continue if no BACKGROUND found
    return () unless defined($Background);

    # non-Unix: set longer $IPC::Exe::_preexec_wait time
    local $IPC::Exe::_preexec_wait = 2;
    if (defined($opt{wait}) && $opt{wait} >= 0)
    {
        $IPC::Exe::_preexec_wait = $opt{wait};
    }

    # dup(2) stdout
    my $ORIGSTDOUT;
    open($ORIGSTDOUT, ">&" . fileno(*STDOUT))
        or warn("IPC::Exe::bg() cannot dup(2) STDOUT\n  $!")
        and return ();

    # double fork -- immediately wait() for child,
    #       and init daemon will wait() for grandchild, once child exits

    # safe pipe open to forked child connected to opened filehandle
    my ($gotchild, $BG_READ, $DUMMY1, $BG_GO1);
    my $defined_child = defined(
        $gotchild = _pipe_from_fork($BG_READ, $DUMMY1, $BG_GO1)
    );

    # check if fork was successful
    unless ($defined_child)
    {
        # decide whether bg() should fallback upon unsuccessful forks
        if ($bg_fallback)
        {
            warn("IPC::Exe::bg() cannot fork child, will try fork again\n  $!");
        }
        else
        {
            warn("IPC::Exe::bg() cannot fork child\n  $!") and return ();
        }
    }

    # parent reads stdout of child process
    if ($gotchild)
    {
        # background: parent reads output from child,
        #                and waits for child to exit
        my $grandpid = <$BG_READ>;
        close($BG_READ);
        return $? ? $gotchild : -+-$grandpid;
    }
    else
    {
        # background: perform second fork
        my ($gotgrand, $DUMMY2, $DUMMY3, $BG_GO2);
        my $defined_grand = defined(
            $gotgrand = $non_unix
                ? _pipe_from_fork($DUMMY2, $DUMMY3, $BG_GO2)
                : fork()
        );

        # check if second fork was successful
        if ($defined_child)
        {
            $defined_grand
                or warn(<<"EOT" . "  $!");
IPC::Exe::bg() cannot fork grandchild, using child instead
 -> parent must wait
EOT
        }
        else
        {
            if ($defined_grand)
            {
                $gotgrand
                    and warn(<<"EOT" . "  $!");
IPC::Exe::bg() managed to fork child, using child now
 -> parent must wait
EOT
            }
            else
            {
                warn(<<"EOT" . "  $!");
IPC::Exe::bg() cannot fork child again, using parent instead
 -> parent does all the work
EOT
            }
        }

        # send grand/child's PID to parent process somehow
        my $childpid;
        if ($defined_grand && $gotgrand)
        {
            if ($defined_child)
            {
                # child writes grandchild's PID to parent process
                print $gotgrand;
            }
            else
            {
                # parent returns child's PID later
                $childpid = $gotgrand;
            }
        }

        # child exits once grandchild is forked
        # grandchild calls BACKGROUND subroutine
        unless ($gotgrand)
        {
            # restore stdout
            open(*STDOUT, ">&" . fileno($ORIGSTDOUT))
                or die("IPC::Exe::bg() cannot restore STDOUT\n  $!");

            # non-Unix: signal parent/child "process" to restore filehandles
            if ($non_unix)
            {
                if (_is_fh($BG_GO2))
                {
                    print $BG_GO2 "bg2\n";
                    close($BG_GO2);
                }

                if (_is_fh($BG_GO1))
                {
                    print $BG_GO1 "bg1\n";
                    close($BG_GO1);
                }
            }

            # BACKGROUND subroutine does not need to return
            { $Background->(@{ $_closure }) }
        }
        elsif (!$defined_child)
        {
            # parent must wait to reap child
            waitpid($gotgrand, 0);
        }

        #  $gotchild  $gotgrand    exit()
        #  ---------  ---------    ------
        #   childpid   grandpid    both child & grandchild
        #   childpid    undef      child
        #    undef     childpid    child
        #    undef      undef      none (parent executes BACKGROUND subroutine)
        exit(0)  if  $defined_child &&  $defined_grand;
        exit(10) if  $defined_child && !$defined_grand;
        exit(10) if !$defined_child &&  $defined_grand && !$gotgrand;

        # falls back here if forks were unsuccessful
        return $childpid;
    }
}

# simulate open(FILEHANDLE, "-|");
# http://perldoc.perl.org/perlfork.html#CAVEATS-AND-LIMITATIONS
sub _pipe_from_fork ($$$) {
    # child writes while parent reads
    my ($pid, $WRITE);

    # cannot fork on these platforms
    return undef if $^O =~ /^(?:VMS|dos|MacOS|riscos|amigaos|vmesa)$/;

    # handle non-Unix platforms
    if ($non_unix)
    {
        # dup(2) stdin/stdout/stderr to be restored later
        my ($ORIGSTDIN, $ORIGSTDOUT, $ORIGSTDERR);

        open($ORIGSTDIN, "<&" . fileno(*STDIN))
            or warn("IPC::Exe cannot dup(2) STDIN\n  $!")
            and return undef;

        open($ORIGSTDOUT, ">&" . fileno(*STDOUT))
            or warn("IPC::Exe cannot dup(2) STDOUT\n  $!")
            and return undef;

        open($ORIGSTDERR, ">&" . fileno(*STDERR))
            or warn("IPC::Exe cannot dup(2) STDERR\n  $!")
            and return undef;

        # create pipe for READHANDLE and WRITEHANDLE
        pipe($_[0], $WRITE) or return undef;

        # create pipe for READYHANDLE and GOHANDLE
        pipe($_[1], $_[2]) or return undef;

        # fork is emulated with threads on Win32
        if (defined($pid = fork()))
        {
            if ($pid)
            {
                close($WRITE);
                close($_[2]);

                # block until signalled to GO!
                #print *STDERR "go> " . readline($_[1]);
                readline($_[1]);

                # restore filehandles after slight delay to allow exec to happen
                my $wait = 400e-6; # default
                $wait = $IPC::Exe::_preexec_wait
                    if defined($IPC::Exe::_preexec_wait);

                usleep($wait * 1e6);
                #print *STDERR "wait> $wait\n";

                open(*STDIN, "<&" . fileno($ORIGSTDIN))
                    or die("IPC::Exe cannot restore STDIN\n  $!");

                open(*STDOUT, ">&" . fileno($ORIGSTDOUT))
                    or die("IPC::Exe cannot restore STDOUT\n  $!");

                open(*STDERR, ">&" . fileno($ORIGSTDERR))
                    or die("IPC::Exe cannot restore STDERR\n  $!");
            }
            else
            {
                close($_[0]);
                close($_[1]);

                # file descriptors are not "process"-persistent on Win32
                open(*STDOUT, ">&" . fileno($WRITE))
                    or die("IPC::Exe cannot establish IPC after fork\n  $!");
            }
        }
    }
    else
    {
        # need this form to allow close($_[0]) to set $? properly
        $pid = open($_[0], "-|");
    }

    return $pid;
}

'IPC::Exe';


__END__

=pod

=head1 NAME

IPC::Exe - Execute processes or Perl subroutines & string them via IPC. Think shell pipes.


=head1 SYNOPSIS

  use IPC::Exe qw(exe bg);

  my @pids = &{
         exe sub { "2>#" }, qw( ls  /tmp  a.txt ),
      bg exe qw( sort -r ),
         exe sub { print "2nd cmd: @_\n"; print "three> $_" while <STDIN> },
      bg exe 'sort',
         exe "cat", "-n",
         exe sub { print "six> $_" while <STDIN>; print "5th cmd: @_\n" },
  };

is like doing the following in a modern Unix shell:

  ls /tmp a.txt 2> /dev/null | { sort -r | [perlsub] | { sort | cat -n | [perlsub] } & } &

except that C<[perlsub]> is really a perl child process with access to main program variables in scope.


=head1 DESCRIPTION

This module was written to provide a secure and highly flexible way to execute external programs with an intuitive syntax. In addition, more info is returned with each string of executions, such as the list of PIDs and C<$?> of the last external pipe process (see L</RETURN VALUES>). Execution uses C<exec> command, and the shell is B<never> invoked (with exception for non-Unix platforms to allow use of C<system>).

The two exported subroutines perform all the heavy lifting of forking and executing processes. In particular, C<exe( )> implements the C<KID_TO_READ> version of

  http://perldoc.perl.org/perlipc.html#Safe-Pipe-Opens

while C<bg( )> implements the double-fork technique illustrated at

  http://perldoc.perl.org/perlfaq8.html#How-do-I-start-a-process-in-the-background?


=head1 EXAMPLES

Let's dive right away into some examples. To begin:

  my $exit = system( "myprog $arg1 $arg2" );

can be replaced with

  my $exit = &{ exe 'myprog', $arg1, $arg2 };

C<exe( )> returns a LIST of PIDs, the last item of which is C<$?> (of default C<&READER>). To get the actual exit value C<$exitval>, shift right by eight C<<< $? >> 8 >>>.

Extending the previous example,

  my $exit = system( "myprog $arg1 $arg2 $arg3 > out.txt" );

can be replaced with

  my $exit = &{ exe sub { open(STDOUT, '>', 'out.txt') or die }, 'myprog', $arg1, $arg2, };

The previous two examples will wait for 'myprog' to finish executing before continuing the main program.

Extending the previous example again,

  # cannot obtain $exit of 'myprog' because it is in background
  system( "myprog $arg1 $arg2 $arg3 > out.txt &" );

can be replaced with

  # just add 'bg' before 'exe' in previous example
  my $bg_pid = &{ bg exe sub { open(STDOUT, '>', 'out.txt') or die }, 'myprog', $arg1, $arg2, };

Now, 'myprog' will be put in background and the main program will continue without waiting.

To monitor the exit value of a background process:

  my $bg_pid = &{
      bg sub {
             # same as 2nd previous example
             my ($pid) = &{
                 exe sub { open(STDOUT, '>', 'out.txt') or die }, 'myprog', $arg1, $arg2,
             };

             # check if exe() was successful
             defined($pid) or die("Failed to fork process in background");

             # handle exit value here
             print STDERR "background exit value: " . ($? >> 8) . "\n";
         }
  };

  # check if bg() was successful
  defined($bg_pid) or die("Failed to send process to background");

Instead of using backquotes or C<qx( )>,

  # slurps entire STDOUT into memory
  my @stdout = (`$program @ARGV`);

  # handle STDOUT here
  for my $line (@stdout)
  {
      print "read_in> $line";
  }

we can read the C<STDOUT> of one process with:

  my ($pid) = &{
      # execute $program with arguments
      exe $program, @ARGV,

      # handle STDOUT here
      sub {
          while (my $line = <STDIN>)
          {
              print "read_in> $line";
          }

          # set exit status of main program
          close($IPC::Exe::PIPE);
      },
  };

  # check if exe() was successful
  defined($pid) or die("Failed to fork process");

  # exit value of $program
  my $exitval = $? >> 8;

Perform tar copy of an entire directory:

  use Cwd qw(chdir);

  my @pids = &{
      exe sub { chdir $source_dir or die }, qw(/bin/tar  cf - .),
      exe sub { chdir $target_dir or die }, qw(/bin/tar xBf -),
  };

  # check if exe()'s were successful
  defined($pids[0]) && defined($pids[1])
      or die("Failed to fork processes");

  # was un-tar successful?
  my $error = pop(@pids);

Here is an elaborate example to pipe C<STDOUT> of one process to the C<STDIN> of another, consecutively:

  my @pids = &{
      # redirect STDERR to STDOUT
      exe sub { "2>&1" }, $program, @ARGV,

      # 'perl' receives STDOUT of $program via STDIN
      exe sub {
              my ($pid) = &{
                  exe qw(perl -e), 'print "read_in> $_" while <STDIN>; exit 123',
              };

              # check if exe() was successful
              defined($pid) or die("Failed to fork process");

              # handle exit value here
              print STDERR "in-between exit value: " . ($? >> 8) . "\n";

              # this is executed in child process
              # no need to return
          },

      # 'sort' receives STDOUT of 'perl'
      exe qw(sort -n),

      # [perlsub] receives STDOUT of 'sort'
      exe sub {
              # find out command of previous pipe process
              # if @_ is empty list, previous process was a [perlsub]
              my ($prog, @args) = @_;
              print STDERR "last_pipe> $prog @args\n"; # output: "last_pipe> sort -n"

              # print sorted, 'perl' filtered, output of $program
              print while <STDIN>;

              # find out exit value of previous 'sort' pipe process
              close($IPC::Exe::PIPE);
              warn("Bad exit for: @_\n") if $?;

              return $?;
          },
  };

  # check if exe()'s were successful
  defined($pids[0]) && defined($pids[1]) && defined($pids[2])
      or die("Failed to fork processes");

  # obtain exit value of last process on pipeline
  my $exitval = pop(@pids) >> 8;

Shown below is an example of how to capture C<STDERR> and C<STDOUT> after sending some input to C<STDIN> of the child process:

  # reap child processes 'xargs' when done
  local $SIG{CHLD} = 'IGNORE';

  # like IPC::Open3, except filehandles are generated on-the-fly
  my ($pid, $TO_STDIN, $FROM_STDOUT, $FROM_STDERR) = &{
      exe +{ stdin => 1, stdout => 1, stderr => 1 }, qw(xargs ls -ld),
  };

  # check if exe() was successful
  defined($pid) or die("Failed to fork process");

  # ask 'xargs' to 'ls -ld' three files
  print $TO_STDIN "/bin\n";
  print $TO_STDIN "does_not_exist\n";
  print $TO_STDIN "/etc\n";

  # cause 'xargs' to flush its stdout
  close($TO_STDIN);

  # print captured outputs
  print "stderr> $_" while <$FROM_STDERR>;
  print "stdout> $_" while <$FROM_STDOUT>;

  # close filehandles
  close($FROM_STDOUT);
  close($FROM_STDERR);

Of course, more C<exe( )> calls may be chained together as needed:

  # reap child processes 'xargs' when done
  local $SIG{CHLD} = 'IGNORE';

  # like IPC::Open2, except filehandles are generated on-the-fly
  my ($pid1, $TO_STDIN, $pid2, $FROM_STDOUT) = &{
      exe +{ stdin  => 1 }, sub { "2>&1" }, qw(perl -ne), 'print STDERR "360.0 / $_"',
      exe +{ stdout => 1 }, qw(bc -l),
  };

  # check if exe()'s were successful
  defined($pid1) && defined($pid2)
      or die("Failed to fork processes");

  # ask 'bc -l' results of "360 divided by given inputs"
  print $TO_STDIN "$_\n" for 2 .. 8;

  # we redirect stderr of 'perl' to stdout
  #   which, in turn, is fed into stdin of 'bc'

  # print captured outputs
  print "360 / $_ = " . <$FROM_STDOUT> for 2 .. 8;

  # close filehandles
  close($TO_STDIN);
  close($FROM_STDOUT);

B<Important:> Some non-Unix platforms, such as Win32, require interactive processes (shown above) to know when to quit, and can neither rely on C<close($TO_STDIN)>, nor C<< kill TERM => $pid; >>


=head1 SUBROUTINES

Both C<exe( )> and C<bg( )> are optionally exported. They each return CODE references that need to be called.

=head2 exe( )

  exe \%EXE_OPTIONS, &PREEXEC, LIST, &READER
  exe \%EXE_OPTIONS, &PREEXEC, &READER
  exe \%EXE_OPTIONS, &PREEXEC
  exe &READER

C<\%EXE_OPTIONS> is an optional hash reference to instruct C<exe( )> to return C<STDIN> / C<STDERR> / C<STDOUT> filehandle(s) of the executed B<child> process. See L</SETTING OPTIONS>.

C<LIST> is C<exec( )> in the child process after the parent is forked, where the child's stdout is redirected to C<&READER>'s stdin.

C<&PREEXEC> is called right before C<exec( )> in the child process, so we may reopen filehandles or do some child-only operations beforehand.

Optionally, C<&PREEXEC> could return a LIST of strings to perform common filehandle redirections and/or C<binmode> settings. The following are preset actions:

  "2>#"  or "2>null"   silence  stderr
   ">#"  or "1>null"   silence  stdout
  "2>&1"               redirect stderr to  stdout
  "1>&2" or ">&2"      redirect stdout to  stderr
  "1><2"               swap     stdout and stderr

  "0:crlf"             does binmode(STDIN, ":crlf");
  "1:raw" or "1:"      does binmode(STDOUT, ":raw");
  "2:utf8"             does binmode(STDERR, ":utf8");

C<&READER> is called with C<LIST> as its arguments. C<LIST> corresponds to the arguments passed in-between C<&PREEXEC> and C<&READER>.

If C<exe( )>'s are chained, C<&READER> calls itself as the next C<exe( )> in line, which in turn, calls the next C<&PREEXEC>, C<LIST>, etc.

C<&PREEXEC> is called with arguments passed to the CODE reference returned by C<exe( )>.

C<&READER> is always called in the parent process.

C<&PREEXEC> is always called in the child process.

C<&PREEXEC> and C<&READER> are very similar and may be treated the same.

It is important to note that the actions & return of C<&PREEXEC> matters, as it may be used to redirect filehandles before &PREEXEC becomes the exec process.

C<close( $IPC::Exe::PIPE )> in C<&READER> to set exit status C<$?> of previous process executing on the pipe.

If C<LIST> is not provided, C<&PREEXEC> will still be called.

If C<&PREEXEC> is not provided, C<LIST> will still exec.

If C<&READER> is not provided, it defaults to

  sub { print while <STDIN>; close($IPC::Exe::PIPE); return $? }

C<exe( &READER )> returns C<&READER>.

C<exe( )> returns an empty list.

=head2 bg( )

  bg \%BG_OPTIONS, &BACKGROUND
  bg &BACKGROUND

C<\%BG_OPTIONS> is an optional hash reference to instruct C<bg( )> to wait a certain amount of time for PREEXEC to complete (for non-Unix platforms only). See L</SETTING OPTIONS>.

C<&BACKGROUND> is called after it is sent to the init process.

If C<&BACKGROUND> is not a CODE reference, return an empty list upon execution.

C<bg( )> returns an empty list.

This experimental feature is not enabled by default:

=over

=item *

Upon failure of background to init process, C<bg( )> can fallback by calling C<&BACKGROUND> in parent or child process if C<$IPC::Exe::bg_fallback> is true. To enable fallback feature, set

  $IPC::Exe::bg_fallback = 1;

=back


=head1 SETTING OPTIONS

=head2 exe( )

C<\%EXE_OPTIONS> is a hash reference that can be provided as the first argument to C<exe( )> to control returned values. It may be used to return C<STDIN> / C<STDERR> / C<STDOUT> filehandle(s) of the child process to emulate L<IPC::Open2> and L<IPC::Open3> behavior.

The default values are:

  %EXE_OPTIONS = (
      stdin       => 0,
      stdout      => 0,
      stderr      => 0,
      autoflush   => 1,
      binmode_io  => undef,
      exec        => 0,  # Win32 option
  );

These are the effects of setting the following options:

=over

=item stdin => 1

Return a B<WRITEHANDLE> to C<STDIN> of the child process. The filehandle will be set to autoflush on write if C<$EXE_OPTIONS{autoflush}> is true.

=item stdout => 1

Return a B<READHANDLE> from C<STDOUT> of the child process, so output to stdout may be captured. When this option is set and C<&READER> is not provided, the default C<&READER> subroutine will B<NOT> be called.

=item stderr => 1

Return a B<READHANDLE> from C<STDERR> of the child process, so output to stderr may be captured.

=item autoflush => 0

Disable autoflush on the B<WRITEHANDLE> to C<STDIN> of the child process. This option only has effect when C<$EXE_OPTIONS{stdin}> is true.

=item binmode_io => ":raw", ":crlf", ":bytes", ":encoding(utf8)", etc.

Set C<binmode> of C<STDIN> and C<STDOUT> of the child process for layer C<$EXE_OPTIONS{binmode_io}>. This is automatically done for subsequently chained C<exe( )>cutions. To stop this, set to an empty string C<""> or another layer to bring a different mode into effect.

=item exec => 1

B<NOTE:> This only applies to non-Unix platforms.

Use C<exec> instead of C<system> when executing programs. This is set automatically when C<$EXE_OPTIONS{stdin}> is or was true in a previous C<exe( )>.

With C<exec>, parent thread does not wait for child to finish, allowing programs that wait for STDIN to not block. This is useful to achieve L<IPC::Open3> behavior where programs wait expecting for further input.

With (default) C<system>, parent thread waits for child to finish and collects the exit status. If the child fails program execution, the parent will cease to continue and return an empty list. This is the way to detect breaks in the chain of C<exe( )>cutions.

=back

=head2 bg( )

B<NOTE:> This only applies to non-Unix platforms.

C<\%BG_OPTIONS> is a hash reference that can be provided as the first argument to C<bg( )> to set wait time (in seconds) before relinquishing control back to the parent thread. See L</CAVEAT> for reasons why this is necessary.

The default value is:

  %BG_OPTIONS = (
      wait => 2,  # Win32 option
  );


=head1 RETURN VALUES

By chaining C<exe( )> and C<bg( )> statements, calling the single returned CODE reference sets off the chain of executions. This B<returns> a LIST in which each element corresponds to each C<exe( )> or C<bg( )> call.

=head2 exe( )

=over

=item *

When C<exe( )> executes an external process, the PID for that process is returned, or an B<EMPTY LIST> if C<exe( )> failed in any operation prior to forking. If an EMPTY LIST is returned, the chain of execution stops there and the next C<&READER> is not called, guaranteeing the final return LIST to be truncated at that point. Failure after forking causes C<die( )> to be called.

=item *

When C<exe( )> executes a C<&READER> subroutine, the subroutine's return value is returned. If there is no explicit C<&READER>, the implicit default C<&READER> subroutine is called instead:

  sub { print while <STDIN>; close($IPC::Exe::PIPE); return $? }

It returns C<$?>, which is the status of the last pipe process close. This allows code to be written like:

  my $exit = &{ exe 'myprog', $myarg };

=item *

When non-default C<\%EXE_OPTIONS> are specified, C<exe( )> returns additional filehandles in the following LIST:

  (
      $PID,                # undef if exec failed
      $STDIN_WRITEHANDLE,  # only if $EXE_OPTIONS{stdin}  is true
      $STDOUT_READHANDLE,  # only if $EXE_OPTIONS{stdout} is true
      $STDERR_READHANDLE,  # only if $EXE_OPTIONS{stderr} is true
  )

The positional LIST form return allows code to be written like:

  my ($pid, $TO_STDIN, $FROM_STDOUT) = &{
      exe +{ stdin => 1, stdout => 1 }, '/usr/bin/bc'
  };

B<Note:> It is necessary to disambiguate C<\%EXE_OPTIONS> (also C<\%BG_OPTIONS>) as a hash reference by including a unary C<+> before the opening curly bracket:

  +{ stdin => 1, autoflush => 0 }
  +{ wait => 2.5 }

=back

=head2 bg( )

Calling the CODE reference returned by C<bg( )> B<returns> the PID of the background process, or an C<EMPTY LIST> if C<bg( )> failed in any operation prior to forking. Failure after forking causes C<die( )> to be called.


=head1 ERROR CHECKING

To determine if either C<exe( )> or C<bg( )> was successful until the point of forking, check whether the returned C<$PID> is defined.

See L</EXAMPLES> for examples on error checking.

B<WARNING:> This may get a slightly complicated for chained C<exe( )>'s when non-default C<\%EXE_OPTIONS> cause the positions of C<$PID> in the overall returned LIST to be non-uniform (caveat emptor). Remember, the chain of executions is doing a B<lot> for just a single CODE call, so due diligence is required for error checking.

A minimum count of items (PIDs and/or filehandles) can be expected in the returned LIST to determine whether forks were initiated for the entire C<exe( )> / C<bg( )> chain.

Failures after forking are responded with C<die( )>. To handle these errors, use C<eval>.


=head1 SYNTAX

It is highly recommended to B<avoid> unnecessary parentheses ( )'s when using C<exe( )> and C<bg( )>.

C<IPC::Exe> relies on Perl's LIST parsing magic in order to provide the clean intuitive syntax.

As a guide, the following syntax should be used:

  my @pids = &{                                          # call CODE reference
      [ bg ] exe [ sub { ... }, ] $prog1, $arg1, @ARGV,  # end line with comma
             exe [ sub { ... }, ] $prog2, $arg2, $arg3,  # end line with comma
      [ bg ] exe sub { ... },                            # this bg() acts on last exe() only
             sub { ... },
  };

where brackets [ ]'s denote optional syntax.

Note that Perl sees

  my @pids = &{
      bg exe $prog1, $arg1, @ARGV,
      bg exe sub { "2>#" }, $prog2, $arg2, $arg3,
         exe sub { 123 },
         sub { 456 },
  };

as

  my @pids = &{
      bg( exe( $prog1, $arg1, @ARGV,
              bg( exe( sub { "2>#" }, $prog2, $arg2, $arg3,
                      exe( sub { 123 },
                           sub { 456 }
                      )
                  )
              )
          )
      );
  };


=head1 CAVEAT

This module is targeted for Unix environments, using techniques described in perlipc and perlfaq8. Development is done on FreeBSD, Linux, and Win32 platforms. It may not work well on other non-Unix systems, let alone Win32.

Some care was taken to rely on Perl's Win32 threaded implementation of C<fork( )>. To get things to work almost like Unix, redirections of filehandles have to be performed in a certain order. More specifically: let's say STDOUT of a child I<process> (read: thread) needs to be redirected elsewhere (anywhere, it doesn't matter). It is important that the parent I<process> (read: thread) does not use STDOUT until B<after> the child is exec'ed. At the point after exec, the parent B<must> restore STDOUT to a previously dup'ed original and may then proceed along as usual. If this order is violated, deadlocks may occur, often manifesting as an apparent stall in execution when the parent tries to use STDOUT.

On Win32, C<bg( )> unfortunately has to substantially rely on timer code to wait for C<&PREEXEC> to complete in order to work properly with C<exe( )>. The example shown below illustrates that C<bg( )> has to wait at least until C<$program> is exec'ed. Hence, C<< $wait_time > $work_time >> must hold true and this requires I<a priori> knowledge of how long C<&PREEXEC> will take.

  &{
      bg +{ wait => $wait_time }, exe sub { sleep($work_time) }, $program
  };

This essentially renders C<bg &BACKGROUND> useless if C<&BACKGROUND> does not exec any programs (Win32).

In summary: (on Win32)

=over

=item *

Only use C<bg( )> to B<exec programs> into the background.

=item *

Keep C<&PREEXEC> as short-running as possible. Or make sure C<$BG_OPTIONS{wait}> time is longer.

=item *

No C<&PREEXEC> (or code running in parallel thread) == no problems.

=back

Some useful information:

  http://perldoc.perl.org/perlfork.html#CAVEATS-AND-LIMITATIONS
  http://www.nntp.perl.org/group/perl.perl5.porters/2003/11/msg85488.html
  http://www.nntp.perl.org/group/perl.perl5.porters/2003/08/msg80311.html
  http://www.perlmonks.org/?node_id=684859
  http://www.perlmonks.org/?node_id=225577
  http://www.perlmonks.org/?node_id=742363


=head1 DEPENDENCIES

Perl v5.6.0+ is required.

The following modules are required:

=over

=item *

L<Exporter> [core module]

=item *

L<POSIX> [core module]

=item *

L<File::Spec> [core module]

=back

Extra module required for non-Unix platforms:

=over

=item *

L<Time::HiRes> [core module]

=back


=head1 AUTHOR

Gerald Lai <glai at cpan dot org>


=cut

