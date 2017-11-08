#!/usr/bin/perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib/";
use TestModule;
use Data::Dumper;

my $params;

foreach my $example_status (qw(NOT_FOUND FAIL NA PASS UNKNOWN)) {
    $params = {
               # next two lines contain module name and perl revision to test it with
               module =>"Acme::CPAN::Testers::$example_status",
               perl_release => "perl-" . $^V =~ s/v//r, #  Whatever our version is, e.g., "5.26.0",
              };

    print "\ncall test_module with:\n";
    print Dumper ($params);

    my $output_hash = TestModule::test_module($params);

    # ; $DB::single=1;

    print "... $params->{module}:\n";
    # print "\n Dump output\n";
    print Dumper %$output_hash{qw(success error grade)};
}

