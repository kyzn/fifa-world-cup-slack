use warnings;
use strict;

=head1 NAME

world-cup-slack 0.01

=cut

package WorldCupSlack;
our $VERSION = '0.01';

use File::Slurper qw/read_text write_text/;
use Furl;
use Getopt::Long;
use List::Util qw/any/;
use JSON::XS;

=head1 DESCRIPTION

Downloads World Cup live game events from FIFA API & posts to Slack.

Run following command to install dependencies.

    cpanm File::Slurper Furl Getopt::Long List::Util JSON::XS

Script comes with a debug mode, where you can pass a timeline.json and
it prints messages to screen. Debug mode requires one time download of
calendar to get team names.

You can set a cronjob to run at every minute to utilize this script.

=head1 SYNOPSIS

First, you will need a Slack incoming webhook URL. Here's how to get it:

=over

=item Create an app at L<https://api.slack.com/apps?new_app=1>

=item Go to your app details page at L<https://api.slack.com>

=item Go to "Incoming webhooks" on left navigation, it will be there.

=back

Post to slack incoming webhook URL.

  perl world-cup-slack.pl --slack=https://hooks.slack.com/services/...

Process an existing JSON file for debug

  perl world-cup-slack.pl --debug=12345678.json

Increase politeness sleep (defaults to 2 seconds)

  perl world-cup-slack.pl --slack=... --sleep=10

You can manually specify location of db.json file.
This may be helpful if you are posting to multiple
workspaces.

  perl world-cup-slack.pl --slack=... --dbjson=/some/file.json

Testing by posting to Slack is also possible. Use following instructions.

=over

=item Remove your db.json file.

=item Run script once with --slack argument provided.

=item Go into db.json and manually update one of the "status:0" games to "status:3"

=item Run script second time, it will collect events and keep them with "posted:0"

=item Run script for third time. It will post all events at once.

=back

=head1 LICENSE

MIT.

=head1 ATTRIBUTION

This script is partly based on
L<j0k3r/worldcup-slack-bot|https://github.com/j0k3r/worldcup-slack-bot>
which was written in PHP.

=cut

my $slack = '';
my $debug = '';
my $sleep = 2;
my $dbjson_filename = './db.json';

GetOptions(
  'slack=s' => \$slack,
  'debug=s' => \$debug,
  'sleep=i' => \$sleep,
  'dbjson=s' => \$dbjson_filename,
) or die 'Encountered an error when parsing arguments';
die 'You have to specify one of --slack OR --debug' unless $slack xor $debug;

# Women's World Cup 2019 in France
my $competition_id = 103;
my $season_id      = 278513;

my $furl = Furl->new;
my @event_types = qw( 0 2 3 4 5 7 8 26 34 39 41 46 60 65 71 72 ); # to be posted
my %event_types = map { $_ => 1 } @event_types;

# To be read from db.json
my $teams   = {}; # $id => $name
my $matches = {}; # $id => { home => $team_id, away => $team_id, stage => $stage_id, status => $status }
                  # Status: 0 Finished, 1 Not started, 3 Live
my $events  = {}; # $id => { match => $match_id, posted => 0/1, desc => "...", score => "..." }
                  # In slack mode, an event is added to db.json with posted 0 first time it's seen
                  # On the next run, 0s become 1 and we do post it to slack
                  # In debug mode, events are posted (to screen) right away and not added to db.json

# Read existing db.json
if (-e $dbjson_filename){
  my $db_json = read_text($dbjson_filename);
  my $db_hash = eval { decode_json($db_json) };
  die 'Could not decode existing db.json' unless $db_hash;
  $teams   = $db_hash->{teams}   // +{};
  $matches = $db_hash->{matches} // +{};
  $events  = $db_hash->{events}  // +{};
}

# Find out which games are live
my @live_matches;
if ($debug){
  # Download calendar in debug mode ONLY IF we don't know about teams yet
  download_calendar() unless %$teams;
  # Use a dummy ID in debug mode, to be replaced with ID from timeline.json
  @live_matches = ( 1 );
} else {
  # Always download calendar in slack mode
  download_calendar();
  # Don't forget there can be more than 1 games running at once
  foreach my $match_id (keys %$matches){
    push @live_matches, $match_id
      if $matches->{$match_id}{status} == 3; # live game
  }
}

foreach my $match_id (@live_matches){
  my $event_hash = download_timeline($match_id);
  $match_id = $event_hash->{IdMatch}; # update for debug.
  my $incoming_events = $event_hash->{Event};
  my $home = $teams->{$matches->{$match_id}{home}};
  my $away = $teams->{$matches->{$match_id}{away}};

  foreach my $e (@$incoming_events){
    my $eid = $e->{EventId};
    # Skip if we don't have a description
    next unless defined $e->{EventDescription}[0];
    # Skip if it's not one of events that we want to post
    next unless $event_types{$e->{Type}};
    # Skip if it's already posted (in slack mode)
    next if $slack && $events->{$eid} && ($events->{$eid}{posted} == 1);

    my $score = get_score($e, $home, $away);
    my $desc  = $e->{EventDescription}[0]{Description};

    if ($slack){ # slack mode
      if ($events->{$eid}){ # event already seen..
        if ($events->{$eid}{posted} == 1){ # and posted.
          next;
        } else { # not posted yet, post it now.
          post($score,$desc);
          $events->{$eid}{posted} = 1;
        }
      } else { # first time seeing this event
        $events->{$eid} = { score => $score, desc => $desc, posted => 0 };
      }
    } else { # debug mode
      post($score,$desc);
    }
  }
}

# Save db.json before finishing up
write_text($dbjson_filename,encode_json({teams=>$teams,matches=>$matches,events=>$events}));


# Helper subroutine to build "score" text
sub get_score {
  my ($event,$home,$away) = @_;
  my $is_penalties = ($event->{Period} == 11) ? 1 : 0;
  my $score = $home . ' ' . $event->{HomeGoals} . ' '
            . ($is_penalties ? '(' . $event->{HomePenaltyGoals} . ') ' : '')
            . '- '
            . ($is_penalties ? '(' . $event->{AwayPenaltyGoals} . ') ' : '')
            . $event->{AwayGoals} . ' ' . $away
            . ($event->{MatchMinute} ? ' (' . $event->{MatchMinute} . ')'  : '');
  return $score;
}


# Helper subroutine to download all matches
# and update their status in db
sub download_calendar {
  my $response = $furl->get(
    "https://api.fifa.com/api/v1/calendar/matches?idCompetition=$competition_id&idSeason=$season_id&count=500&language=en-GB"
  );
  die 'Error encountered when downloading calendar' unless $response->is_success;
  sleep $sleep;

  my $content = $response->content;
  my $json    = eval { decode_json($content) };
  die 'Error encountered when parsing calendar response' unless $json;

  my @games = grep { $_->{Home} && $_->{Away} } @{$json->{Results}};
  die 'No results found in calendar' unless scalar @games;

  foreach my $game (@games){
    $teams->{$game->{Home}{IdTeam}} = $game->{Home}{TeamName}[0]{Description};
    $teams->{$game->{Away}{IdTeam}} = $game->{Away}{TeamName}[0]{Description};
    $matches->{$game->{IdMatch}} = {
      home   => $game->{Home}{IdTeam},
      away   => $game->{Away}{IdTeam},
      stage  => $game->{IdStage},
      status => $game->{MatchStatus},
    }
  }
}


# Helper subroutine to download timeline
# Return hashref of events as downloaded
# Debug mode reads from file instead
sub download_timeline {
  my $match_id = shift;
  my $content;

  if ($debug){
    $content = read_text($debug);
    die 'Error encountered when reading debug file' unless $content;
  } else {
    my $stage_id = $matches->{$match_id}{stage};
    my $response = $furl->get(
      "https://api.fifa.com/api/v1/timelines/$competition_id/$season_id/$stage_id/$match_id?language=en-GB"
    );
    die 'Error encountered when downloading timeline' unless $response->is_success;
    $content = $response->content;
    sleep $sleep;
  }

  my $json = eval { decode_json($content) };
  die 'Error encountered when parsing timeline content' unless $json;

  return $json;
}


# Helper subroutine to post data
sub post {
  my ($score, $desc) = @_;
  if ($slack){
    $furl->post(
      $slack,
      ["Content-type" => "application/json"],
      encode_json {"text" => "*$score*\n> $desc"},
    );
  } else {
    print '-'x30;
    print "\n$score\n$desc\n";
  }
}
