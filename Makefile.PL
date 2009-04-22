use 5.006_000;
use ExtUtils::MakeMaker;

die("OS unsupported\n") if $^O =~ /^(?:VMS|dos|MacOS|riscos|amigaos|vmesa)$/;

# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    NAME              => 'IPC::Exe',
    VERSION_FROM      => 'lib/IPC/Exe.pm',
    PREREQ_PM         => {
                             'POSIX'       => 0,
                             'File::Spec'  => 0,
                             'Time::HiRes' => 0,
                         },

    ($] >= 5.005 ?     ## Add these new keywords supported since 5.005
      (ABSTRACT_FROM  => 'lib/IPC/Exe.pm',
       LICENSE        => 'perl',
       AUTHOR         => 'Gerald Lai <glai at cpan dot org>') : ()),
);
