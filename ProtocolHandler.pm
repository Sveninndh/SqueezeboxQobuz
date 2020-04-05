package Plugins::Qobuz::ProtocolHandler;

#Sven 2020-04-04 enhancements based on version 1.400 up to 2.000

# Handler for qobuz:// URLs

use strict;
use base qw(Slim::Player::Protocols::HTTP);
use Scalar::Util qw(blessed);

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;

use Plugins::Qobuz::API;
use Plugins::Qobuz::API::Common;
use Plugins::Qobuz::Reporting;

use constant MP3_BITRATE => 320_000;

my $log   = logger('plugin.qobuz');
my $prefs = preferences('plugin.qobuz');

sub new {
	my $class  = shift;
	my $args   = shift;

	my $client    = $args->{client};
	my $song      = $args->{song};
	my $streamUrl = $song->streamUrl() || return;

	main::DEBUGLOG && $log->is_debug && $log->debug( 'Remote streaming Qobuz track: ' . $streamUrl );

	my $mime = $song->pluginData('mime');

	my $sock = $class->SUPER::new( {
		url     => $streamUrl,
		song    => $song,
		client  => $client,
#		bitrate => $mime =~ /flac/i ? 750_000 : MP3_BITRATE,
	} ) || return;

	${*$sock}{contentType} = $mime;

	return $sock;
}

sub canSeek { 1 }

sub getSeekDataByPosition { undef }

sub getSeekData {
	my ( $class, $client, $song, $newtime ) = @_;

	my $url = $song->currentTrack()->url() || return;

	my ($id, $type) = $class->crackUrl($url);
	
#Sven 2019-03-28 allows seeking in flac files, see also parseDirectHeaders()	
	my $bitrate = $type eq 'mp3' ? MP3_BITRATE : $song->bitrate();

	return unless $bitrate;

	return {
		sourceStreamOffset => ( $bitrate  * $newtime ) / 8,
		timeOffset         => $newtime,
	};
}

sub scanUrl {
	my ($class, $url, $args) = @_;
	$args->{cb}->( $args->{song}->currentTrack() );
}

sub getFormatForURL {
	my ($class, $url) = @_;

	my ($id, $type) = $class->crackUrl($url);

	if ($type =~ /^(flac|mp3)$/) {
		$type =~ s/flac/flc/;
		return $type;
	}

	my $info = Plugins::Qobuz::API->getCachedFileInfo($id || $url);

	return $info->{mime_type} =~ /flac/ ? 'flc' : 'mp3' if $info && $info->{mime_type};

	# fall back to whatever the user can play
	return Plugins::Qobuz::API::Common->getStreamingFormat();
}

sub canDirectStreamSong {
	my ( $class, $client, $song ) = @_;

	# We need to check with the base class (HTTP) to see if we
	# are synced or if the user has set mp3StreamingMethod
	return $class->SUPER::canDirectStream( $client, $song->streamUrl() );
}

# parseHeaders is used for proxied streaming
sub parseHeaders {
	my ( $self, @headers ) = @_;

	__PACKAGE__->parseDirectHeaders( $self->client, $self->url, @headers );

	return $self->SUPER::parseHeaders( @headers );
}

sub parseDirectHeaders {
	my $class   = shift;
	my $client  = shift || return;
	my $url     = shift;
	my @headers = @_;

	# May get a track object
	if ( blessed($url) ) {
		$url = $url->url;
	}

	my $bitrate     = 750_000;
	my $contentType = 'flc';

	my $length;

	foreach my $header (@headers) {
		if ( $header =~ /^Content-Length:\s*(.*)/i ) {
			$length = $1;
		}
		#Sven 2019-03-29 allows seeking in flac files, see getSeekData()
		elsif ( $header =~ /^Content-Range:.*\/+(.*)/i ) {
			$length = $1;
		}
		elsif ( $header =~ /^Content-Type:.*(?:mp3|mpeg)/i ) {
			$bitrate = MP3_BITRATE;
			$contentType = 'mp3';
		}
	}

	my $song = $client->streamingSong();

	# try to calculate exact bitrate so we can display correct progress
	my $meta = $class->getMetadataFor($client, $url);
	my $duration = $meta->{duration};

	# sometimes we only get a 60s/mp3 sample
	if ($meta->{streamable} && $meta->{streamable} eq 'sample' && $contentType eq 'mp3') {
		$duration = 60;
	}

	$song->duration($duration);

	if ($length && $contentType eq 'flc') {
		$bitrate = $length*8 / $duration if $duration; #Sven 2019-03-29
		$song->bitrate($bitrate) if $bitrate;
	}

	if ($client) {
		$client->currentPlaylistUpdateTime( Time::HiRes::time() );
		Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
	}

	Plugins::Qobuz::Reporting->startStreaming($client);

	# title, bitrate, metaint, redir, type, length, body
	return (undef, $bitrate, 0, undef, $contentType, $length, undef);
}

sub getMetadataFor {
	my ( $class, $client, $url ) = @_;

	my ($id) = $class->crackUrl($url);
	$id ||= $url;

	my $meta;

	# grab metadata from backend if needed, otherwise use cached values
	if ($id && $client && $client->master->pluginData('fetchingMeta')) {
		Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] ) if $client;
		$meta = Plugins::Qobuz::API->getCachedFileInfo($id);
	}
	elsif ($id) {
		$client->master->pluginData( fetchingMeta => 1 ) if $client;

		$meta = Plugins::Qobuz::API->getTrackInfo(sub {
			$client->master->pluginData( fetchingMeta => 0 ) if $client;
		}, $id);
	}

	$meta ||= {};
	if ($meta->{mime_type} && $meta->{mime_type} =~ /(fla?c|mp)/) {
		$meta->{type} = $meta->{mime_type} =~ /fla?c/ ? 'flc' : 'mp3';
	}
	$meta->{type} ||= $class->getFormatForURL($url);
	$meta->{ct} = $meta->{type};
	$meta->{bitrate} = $meta->{type} eq 'mp3' ? MP3_BITRATE : 750_000;

	if ($meta->{type} ne 'mp3' && $client && $client->playingSong && $client->playingSong->track->url eq $url) {
		$meta->{bitrate} = $client->playingSong->bitrate if $client->playingSong->bitrate;
		#Sven 20190323 allows displaying samplerate and samplesize in 'More Info' menu
		$meta->{samplerate} = $client->playingSong->pluginData('samplerate');
		$meta->{samplesize} = $client->playingSong->pluginData('samplesize');
	}

	$meta->{bitrate} = sprintf("%.0f" . Slim::Utils::Strings::string('KBPS'), $meta->{bitrate}/1000);

	if ($meta->{composer} && $prefs->get('showComposerWithArtist') && $meta->{artist} !~ /$meta->{composer}/) {
		$meta->{artist} .= ', ' . $meta->{composer};
	}

	if ($meta->{cover} && ref $meta->{cover}) {
		$meta->{cover} = Plugins::Qobuz::API::Common->getImageFromImagesHash($meta->{cover});
	}

	return $meta;
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;

	my $url = $song->currentTrack()->url;

	# Get next track
	my ($id, $format) = $class->crackUrl($url);

	Plugins::Qobuz::API->getFileInfo(sub {
		my $streamData = shift;

		if ($streamData) {
			$song->pluginData(mime => $streamData->{mime_type});

			#Sven 20190323 allows displaying samplerate and samplesize in 'More Info' menu
			$song->pluginData(samplesize => $streamData->{bit_depth});
			$song->pluginData(samplerate => $streamData->{sampling_rate});

			Plugins::Qobuz::API->getFileUrl(sub {
				$song->streamUrl(shift);
				$successCb->();
			}, $id, $format);
			return;
		}

		$errorCb->('Failed to get next track', 'Qobuz');
	}, $id, $format);
}

sub crackUrl {
	my ($class, $url) = @_;

	return unless $url;

	my ($id, $format) = $url =~ m{^qobuz://(.+?)\.(mp3|flac)$};

	# compatibility with old urls without extension
	($id) = $url =~ m{^qobuz://([^\.]+)$} unless $id;
	($id) = $url =~ m{^https?://.*?eid=(\d+)} unless $id;

	return ($id, $format || Plugins::Qobuz::API::Common->getStreamingFormat($url));
}

sub audioScrobblerSource {
	# Scrobble as 'chosen by user' content
	return 'P';
}

1;