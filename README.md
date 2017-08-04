# testers
A rewrite of Ray's Perl Smoker Testers program

See https://github.com/raytestinger/testers

Purpose: To run tests on modules that are newly updated in CPAN
(or any other desired set of modules).

The results may be stored locally or transmitted to the CPAN testers,
from which they may be viewed.  Further information on accessing test
results:

http://blogs.perl.org/users/preaction/2017/07/cpan-testers-has-an-api.html


This uses Mojo and Minion to divide the testing into steps, each of
which is performed and controlled by the Minion job queue.

To begin, build a database and download the list of packages from
CPAN:

    $ perl smoketest update --rebuild

Example use from a locally saved copy of the package list:

    $ perl smoketest update ~/Documents/02packages.details.txt --rebuild

to rebuild and reload database from a local file, or:

    $ perl smoketest update

to update from the default CPAN location (remote URL)

If you `chmod a+x smoketest` then continue by downloading the default
Disabled list:

    $ ./smoketest disable

NOTE: The above step uses a YAML file which should contain (1) a regex
that selects one or more modules by name; and (2) the setting
disabled=1.  Alternately, if it says disabled=0 then the regex will
*enable* the selected modules.

TODO: Also allow loading local files and setting priority, as:

    $ ./smoketest disable ~/mydisabled.yml --priority 10

TODO: Pick a better verb instead of the possibly misleading 'disable'

Next, apply the enabled/disabled module lists in priority order:

    $ ./smoketest apply

To create a series of jobs which will test each enabled module:

    $ ./smoketest create

Then start a worker process to actually perform the tests:

    $ ./smoketest minion worker &

You can monitor the progress by either examining the Minion job queue
directly:

     $ ./smoketest minion -s               # shows overall status
     $ ./smoketest minion job -S inactive  # shows queued jobs
     $ ./smoketest minion job -S finished  # shows completed jobs

or by pointing your browser at http://localhost:3000

    /modules           module statistics
    /module/:modname   information about given module
    /tests/:modname    list of tests performed on a module
    /update            queue a job which will download the
                       module list from CPAN
    /update/*uri       download the module list from a location
    /apply             apply the Disabled list
    /job/:id           status of a given minion job
    del /job/:id       remove a minion job by id_number
    /jobs/stats        minion stats


==========

running cpanm-reporter for first time:

  See CPAN::Testers::Common::Client::Config documentation for more
  details.

asks a bunch of options and then:

  CPAN Testers: writing config file to '/home/billl/.cpanreporter/config.ini'.


==========

releases within last 2 days --? izzit true?

curl -XPOST 'https://fastapi.metacpan.org/v1/file' -d "$(curl -Ls gist.github.com/metacpan-user/5705999/raw/body.json)"

with:

---begin---
{
  "query": {
    "match_all": {}
  },
  "filter": {
    "and": [
      {
        "term": {
          "path": "cpanfile"
        }
      },
      {
        "term": {
          "status": "latest"
        }
      },
      {
        "range" : {
            "date" : {
                "gte" : "now-2d/d",
                "lt" :  "now/d"
            }
        }        
      }    
    ]
  },
  "fields": [
    "release", "date"
  ],
  "size": 200
}
---end---

or:

---begin---
{ "query": { "match_all": {} }, "filter": { "and": [ { "term": { "path": "cpanfile" } }, { "term": { "status": "latest" } }, { "or": [ {"term" : { "author" : "PREACTION" } }, {"term" : { "author" : "JBERGER" }} ] } ] }, "fields": [ "release", "date", "author" ], "size": 200 }
---end---

                                                                                 
{ 'size' => 200,
  'fields' => ['release', 'date', 'author', 'download_url', 'version'],
  'filter' => {'and' => [ {'term' => {'path' => 'cpanfile'}},
                          {'term' => {'status' => 'latest'}},
                          {'or' => [{'term' => {'author' => 'PREACTION'}},
                                      {'term' => {'author' => 'JBERGER'}}]}
                         ]},
  'query' => {'match_all' => {}}
}

