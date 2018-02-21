#!/usr/bin/perl

use strict;
use warnings;

my $childPid;
eval {
        local $SIG{ALRM} = sub { die "alarm\n" };
        alarm 1;
        if ($childPid = fork()) {
                wait();
        } else {
            my $command = 'cpanm --test-only -L /tmp/perl_libs/5.24.1 https://cpan.metacpan.org/authors/id/E/ET/ETHER/Moose-2.2010.tar.gz';
            # $command = 'perlbrew exec --with 5.24.1 ' . $command;
            exec($command);
        }
        alarm 0;
};
if ($@) {
        die $@ unless $@ eq "alarm\n";
        print "timed out: pid= $childPid\n";
        kill 2, $childPid;
        wait;
};
exit;
