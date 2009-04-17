#!/usr/bin/perl

use warnings;
use strict;

use Data::Dumper;
use IPC::Exe qw(exe bg);

my @pids = &{
       exe sub { "2>#" }, qw( ls  /tmp  a.txt ),
    bg exe qw( sort -r ),
       exe sub { print "2nd cmd: @_\n"; print "three> $_" while <STDIN> },
    bg exe 'sort',
       exe "cat", "-n",
       exe sub { print "six> $_" while <STDIN>; print "5th cmd: @_\n" },
};

# two PIDs returned: 'ls' & background job
print Dumper(\@pids);

