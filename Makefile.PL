use 5.006_000;
use ExtUtils::MakeMaker;

die("OS unsupported\n") if $^O =~ /^(?:VMS|dos|MacOS|riscos|amigaos|vmesa)$/;

WriteMakefile(
    NAME         => 'IPC::Exe',
    VERSION_FROM => 'lib/IPC/Exe.pm',

    ( $] >= 5.005 ?
        (
            ABSTRACT_FROM  => 'lib/IPC/Exe.pm',
            LICENSE        => 'perl',
            AUTHOR         => 'Gerald Lai <glai at cpan dot org>',
        ) : ()
    ),

    ## DEPENDENCIES ##
    PREREQ_PM => {
                     'POSIX'       => 0,
                     'File::Spec'  => 0,
                     'Time::HiRes' => 0,
                 },
);
