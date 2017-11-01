#!/usr/bin/perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib/";
use TestModule;
use Data::Dumper;


my %params;
%params = (
	# next two lines contain module name and perl revision to test it with
    module =>'Acme::CPAN::Testers::FAIL',
    perl_release => "perl-5.26.0",
);

print "\ncall test_module with:\n";
print Dumper (\%params);

my $output_hash = TestModule::test_module(\%params);

; $DB::single=1;

print "\n Dump output\n";
print Dumper $output_hash;


__END__


my %params;
%params = (
	# next two lines contain module name and perl revision to test it with
    module =>'http://cpan.cpantesters.org/authors/id/D/DA/DAGOLDEN/Acme-Devel-Hide-Tiny-0.001.tar.gz',
    perl_release => "perl-5.20.3",
);

print "\ncall test_module with:\n";
print Dumper (\%params);

my @outputs = TestModule::test_module(\%params);

print "\n Dump output\n";
print Dumper @outputs;
%params = (
    module =>'http://cpan.cpantesters.org/authors/id/D/DA/DAGOLDEN/Acme-Devel-Hide-Tiny-0.001.tar.gz',
    perl_release => "perl-5.22.0",
);

print "\ncall test_module with:\n";
print Dumper (\%params);

my @outputs = TestModule::test_module(\%params);

print "\n Dump output\n";
print Dumper @outputs;
%params = (
    module =>'http://cpan.cpantesters.org/authors/id/D/DA/DAGOLDEN/Acme-Devel-Hide-Tiny-0.001.tar.gz',
    perl_release => "perl-5.24.0",
);

print "\ncall test_module with:\n";
print Dumper (\%params);

@outputs = TestModule::test_module(\%params);

print "\n Dump output\n";
print Dumper @outputs;
%params = (
    module =>'http://cpan.cpantesters.org/authors/id/D/DA/DAGOLDEN/Acme-Devel-Hide-Tiny-0.001.tar.gz',
    perl_release => "perl-5.26.0",
);

print "\ncall test_module with:\n";
print Dumper (\%params);

@outputs = TestModule::test_module(\%params);

print "\n Dump output\n";
print Dumper @outputs;
