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
    module =>'http://cpan.cpantesters.org/authors/id/D/DA/DAGOLDEN/Acme-Devel-Hide-Tiny-0.001.tar.gz',
    perl_release => "perl-5.20.3",
    
    # next four lines contain contents of config.ini file for cpanm-reporter
    edit_report => 0,
    email_from  => '"testinger" <raytestinger@yahoo.com>',
    send_report => 1,
    transport => 'File /media/sg/cpantesters/miniature-engine/testers/smoke/.cpantesters',
);
#   transport => 'Metabase uri https://metabase.cpantesters.org/api/v1/ id_file metabase_id.json',

print "\ncall test_module with:\n";
print Dumper (\%params);

my $outputs = TestModule::test_module(\%params);

print "\n Dump output\n";
print Dumper $outputs;
%params = (
    module =>'http://cpan.cpantesters.org/authors/id/D/DA/DAGOLDEN/Acme-Devel-Hide-Tiny-0.001.tar.gz',
    perl_release => "perl-5.22.0",
    edit_report => 0,
    email_from  => '"testinger" <raytestinger@yahoo.com>',
    send_report => 1,
    transport => 'File /media/sg/cpantesters/miniature-engine/testers/smoke/.cpantesters',
);
#   transport => 'Metabase uri https://metabase.cpantesters.org/api/v1/ id_file metabase_id.json',

print "\ncall test_module with:\n";
print Dumper (\%params);

my $outputs = TestModule::test_module(\%params);

print "\n Dump output\n";
print Dumper $outputs;
%params = (
    module =>'http://cpan.cpantesters.org/authors/id/D/DA/DAGOLDEN/Acme-Devel-Hide-Tiny-0.001.tar.gz',
    perl_release => "perl-5.24.0",
    edit_report => 0,
    email_from  => '"testinger" <raytestinger@yahoo.com>',
    send_report => 1,
    transport => 'File /media/sg/cpantesters/miniature-engine/testers/smoke/.cpantesters',
);
#   transport => 'Metabase uri https://metabase.cpantesters.org/api/v1/ id_file metabase_id.json',

print "\ncall test_module with:\n";
print Dumper (\%params);

my $outputs = TestModule::test_module(\%params);

print "\n Dump output\n";
print Dumper $outputs;
%params = (
    module =>'http://cpan.cpantesters.org/authors/id/D/DA/DAGOLDEN/Acme-Devel-Hide-Tiny-0.001.tar.gz',
    perl_release => "perl-5.26.0",
    edit_report => 0,
    email_from  => '"testinger" <raytestinger@yahoo.com>',
    send_report => 1,
    transport => 'File /media/sg/cpantesters/miniature-engine/testers/smoke/.cpantesters',
);
#   transport => 'Metabase uri https://metabase.cpantesters.org/api/v1/ id_file metabase_id.json',

print "\ncall test_module with:\n";
print Dumper (\%params);

my $outputs = TestModule::test_module(\%params);

print "\n Dump output\n";
print Dumper $outputs;
