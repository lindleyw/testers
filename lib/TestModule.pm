package TestModule;

use v5.10;
use Data::Dumper;
use Mojo::File;
use File::Temp;
use CPAN::Testers::Common::Client::Config;

use strict;
use warnings;

my $verbose = 1;

sub test_module {
    say "\nentering test_module\n" if ($verbose);
    system("date") if ($verbose);

    my ($params) = shift;
    say Dumper ($params) if ($verbose);

    # Find where our reports are going to be located
    my $cf = CPAN::Testers::Common::Client::Config->new;

    $cf->read;

    my $temp_dir_name = File::Temp->newdir;
    # by default this uses CLEANUP => 1 (c.f. File::Temp doc)

    my $module       = $params->{module};
    my $perl_release = $params->{perl_release};

    # next two variable settings are explained in this link
    # http://www.dagolden.com/index.php/2098/the-annotated-lancaster-consensus
    local $ENV{NONINTERACTIVE_TESTING} = 1;
    local $ENV{AUTOMATED_TESTING}      = 1;

    local $ENV{PERL_CPANM_HOME}     = $temp_dir_name;
    my $cpanm_test_command = "perlbrew exec --with $perl_release ";
    $cpanm_test_command .= "cpanm --test-only $module ";
    say "cpanm_test_command $cpanm_test_command" if ($verbose);
    check_exit('test', system("$cpanm_test_command") );

    # Probably not required?  -- wl 20171101
    # #   these hard coded paths will be replaced with soft paths
    # my $build_file = "$ENV{PERL_CPANM_HOME}/latest-build/build.log";
    # say "current build log $build_file" if ($verbose);
    # system("cat $build_file") if ($verbose);;

    # Both the build log and the report log, can go into the same directory
    # cpanm-reporter will put its report in the directory
    # indicated by the 'transport' setting in file config.ini
    # in the ~/.cpanmreporter directory
    # ~/.cpanmreporter
    local $ENV{CPANM_REPORTER_HOME} = $temp_dir_name;
    my $config_file = Mojo::File->new($temp_dir_name)->child('config.ini');

    # local $ENV{PERL_CPAN_REPORTER_DIR} = $temp_dir_name; # directory for config.ini:
    local $ENV{PERL_CPAN_REPORTER_CONFIG} = $config_file->to_string; # exact location of config.ini

    my $email = $cf->email_from;
    $config_file->spurt(<<CONFIG);
edit_report=default:no
email_from=$email
send_report=default:yes
transport=File $temp_dir_name
CONFIG

    # We should now have a config.ini that cpanm-reporter will pick up.
    # ; $DB::single = 1;

    my $build_file = Mojo::File->new($temp_dir_name)->child('build.log');
    my $cpanm_reporter_command = "perlbrew exec --with $perl_release " .
    "cpanm-reporter --verbose " .
    "--build_dir=$temp_dir_name " .
    "--build_logfile=$build_file " .
     "--skip-history --ignore-versions --force ";
    check_exit('reporter', system($cpanm_reporter_command) );

    # At long last, our hero returns and discovers:
    # ${temp_dir_name}/{Status}.{module_name}-{build_env_stuff}.{timestamp}.{pid}.rpt
    # ${temp_dir_name}/work/{timestamp}.{pid}/build.log

    my $test_results = Mojo::File->new($temp_dir_name)->list_tree;
    # Find the report file.  Extract the result (e.g., 'fail') and return with the filename.
    my $report_file = $test_results->map(sub {
                                             /^${temp_dir_name}.(\w+)\..*\.(\d+)\.(\d+)\.rpt/
                                             ? ($_, $1): ()});

    my ($report_filename, $grade);
    if ($report_file->size) { # Found.
        $report_filename = $report_file->[0]->to_string;
        $grade = $report_file->[1];
    }
    my $build_log = $test_results->grep(sub { /build.log$/ && !-l $_})->first; # ignore symlinks
    return {
            build_log => Mojo::File->new($build_log)->slurp,
            report    => Mojo::File->new($report_filename)->slurp,
            grade     => $grade,
           };
}

sub check_exit {
    my ($what, $exit) = @_;
    if ( $exit == -1 ) {
        say "$what failed to execute: $!";
    }
    elsif ( $exit & 127 ) {
        printf "$what child died with signal %d, %s coredump\n",
          ( $exit & 127 ), ( $exit & 128 ) ? 'with' : 'without';
    }
    else {
        printf "$what child exited with value %d\n", $exit >> 8;
    }
}

1;

