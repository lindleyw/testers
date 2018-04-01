use strict;
use warnings;

###
### Submission of reports to CPAN Testers.
###

package CPAN::TestersDB {

    use Mojo::Base '-base';

    has 'log';
    has 'config';
    has 'user_email';

    # NOTE: On the system running CPAN::Testers::API, the following query will
    # show the resulting test records:
    # MariaDB>  select id, json_extract(report,'$[0].distribution.name') as name,
    #           json_extract(report,'$[0].distribution.version') as version,
    #           json_extract(report,'$[0].result.grade') as grade
    #           from test_report limit 10;

    sub report_json {
        # Formats a test report per the CPAN::Testers::API submission standard
        my ($self, $test) = @_;

        return undef unless defined $test;
        my ($release_name, $release_version) = $test->{name} =~ m{^(.+)-([^-]+)};
        $self->log->info("report_json ($release_name)");
        return { environment => { language => { name => 'Perl 5',
                                                version => $test->{perl},
                                                archname => $test->{archname},
                                              },
                                  system => { osname => $test->{osname},
                                              osversion => $test->{osvers},
                                            },
                                },
                 reporter => $self->user_email,
                 distribution => { name => $release_name,
                                   version => $test->{version}, # should be same as $release_version
                                 },
                 result => { grade => $test->{grade},
                             output => { uncategorized => $test->{report} },
                             duration => ($test->{duration} // $test->{elapsed_time} // 0) +.5,
                             # XXX: Question: Do we want $test->{build_log} ?
                             # NOTE: {build_log} is the combined stdout+stderr;
                             # see Tester::Single::check_exit()
                           },
                 user_agent => $self->config->{user_agent} // 'Smoketest/'.$::VERSION,
               };
    }

    sub submit_report {
        my ($self, $test_json) = @_;

        my $ua = Mojo::UserAgent->new();
        my $source_url = Mojo::URL->new($self->config->{submit_url});

        if ($test_json->{result}->{grade} !~ /^(pass|fail|na)/) {
            $self->log->info("Skipping report (".$test_json->{distribution}->{name}.'-'.$test_json->{distribution}->{version}.
                             "): unknown grade=" . $test_json->{result}->{grade});
            return;
        }

        my $result = eval { $ua->max_redirects(5)->post($source_url,
                                                       json => $test_json); };
        # $DB::single = 1;
        $self->log->info("Submit report ($source_url): result code=" .  $result->res->{code})
            if (defined $result);
        return (!defined $result) ? undef : { url => $source_url,         # where we submitted
                                              code => $result->res->code,
                                              body => $result->res->body,
                                              message => $result->res->message };
    }

    sub get_module_info {
        # Get metacpan information for a module, or for a release (type='release')
        my ($self, $module_name, $type) = @_;

        my $ua = Mojo::UserAgent->new();
        my $source_url = Mojo::URL->new($self->config->{metacpan}->{$type // 'module'}); # API endpoint
        push @{$source_url->path->parts}, $module_name;
    }

};

1;
