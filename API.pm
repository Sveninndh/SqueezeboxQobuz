package Plugins::Qobuz::API;

#Sven 2024-02-25 enhancements version 30.2.0
# All changes are marked with "#Sven" in source code
# 2020-03-30 getArtist() new parameter $noalbums, if it is not undef, getArtist() returns no extra album information
# 2022-05-12 fix in function getPublicPlaylists()
# 2022-05-13 added function setFavorite()
# 2022-05-13 added function getFavoriteStatus()
# 2022-05-13 add filter parameter for function getUserPlaylists()
# 2022-05-14 added function doPlaylistCommand()
# 2022-05-20 added MyWeekly playlist
# 2022-05-20 new parameter $type for getUserFavorites()
# 2022-05-23 getAlbum() new parameter 'extra' and one optimisation
# 2022-05-23 added getLabelAlbums()
# 2022-05-23 added function getSimilarPlaylists()
# 2023-10-07 Update of app_id handling
# 2023-10-09 add sort configuration for function getUserPlaylists()

use strict;
use base qw(Slim::Utils::Accessor);

use File::Spec::Functions qw(catdir);
use FindBin qw($Bin);

use JSON::XS::VersionOneAndTwo;
use List::Util qw(min max);
use URI::Escape qw(uri_escape_utf8);
use Digest::MD5 qw(md5_hex);
use Scalar::Util qw(blessed);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::Qobuz::API::Common;

use constant URL_EXPIRY => 60 * 10;       # Streaming URLs are short lived
use constant BROWSER_UA => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2.1 Safari/605.1.15';

# bump the second parameter if you decide to change the schema of cached data
my $cache = Plugins::Qobuz::API::Common->getCache();
my $prefs = preferences('plugin.qobuz');
my $log = logger('plugin.qobuz');

my %apiClients;

{
	__PACKAGE__->mk_accessor( rw => qw(
		client
		userId
	) );
}

sub new {
	my ($class, $args) = @_;

	if (!$args->{client} && !$args->{userId}) {
		return;
	}

	my $client = $args->{client};
	my $userId = $args->{userId} || $prefs->client($client)->get('userId') || return;

	if (my $apiClient = $apiClients{$userId}) {
		return $apiClient;
	}

	my $self = $apiClients{$userId} = $class->SUPER::new();
	$self->client($client);
	$self->userId($userId);

	# update our profile ASAP
	$self->updateUserdata();

	return $self;
}

my ($aid, $as, $cid);

sub init {
	($aid, $as, $cid) = Plugins::Qobuz::API::Common->init(@_);
}

sub login {
	my ($class, $username, $password, $cb, $args) = @_;

	if ( !($username && $password) ) {
		$cb->() if $cb;
		return;
	}

	my $params = {
		username => $username,
		password => $password,
		device_manufacturer_id => preferences('server')->get('server_uuid'),
		_nocache => 1,
		_cid     => $args->{cid} ? 1 : 0,
	};

	$class->_get('user/login', sub {
		my $result = shift;

		main::INFOLOG && $log->is_info && !$log->is_info && $log->info(Data::Dump::dump($result));

		my ($token, $user_id);
		if ( ! ($result && ($token = $result->{user_auth_token}) && $result->{user} && ($user_id = $result->{user}->{id})) ) {
			$log->warn('Failed to get token');
			$cb->() if $cb;
			return;
		}

		my $accounts = $prefs->get('accounts') || {};

		if (!$args || !$args->{cid}) {
			$accounts->{$user_id}->{token} = $token;
			$accounts->{$user_id}->{userdata} = $result->{user};

			$class->login($username, $password, sub {
				$cb->(@_) if $cb;
			}, {
				cid => 1,
				token => $token,
			});
		}
		else {
			$accounts->{$user_id}->{webToken} = $token;
			$cb->($args->{token}) if $cb;
		}

		$prefs->set('accounts', $accounts);
	}, $params);
}

sub updateUserdata {
	my ($self, $cb) = @_;

	$self->_get('user/get', sub {
		my $result = shift;

		if ($result && ref $result eq 'HASH') {
			my $userdata = Plugins::Qobuz::API::Common->getUserdata($self->userId);

			foreach my $k (keys %$result) {
				$userdata->{$k} = $result->{$k} if defined $result->{$k};
			}

			$prefs->save();
		}

		$cb->($result) if $cb;
	},{
		user_id => $self->userId,
		_nocache => 1,
	})
}

sub getMyWeekly {
	my ($self, $cb) = @_;

	$self->_get('dynamic-tracks/get', sub {
		my $myWeekly = shift;

		$myWeekly->{tracks}->{items} = _precacheTracks($myWeekly->{tracks}->{items} || []) if $myWeekly->{tracks};

		$cb->($myWeekly);
	}, {
		type        => 'weekly',
		limit       => 50,
		offset      => 0,
		_ttl        => 60 * 60 * 12,
		_use_token  => 1,
		_cid        => 1,
	});
}

sub search {
	my ($self, $cb, $search, $type, $args) = @_;

	$args ||= {};

	$search = lc($search);

	main::INFOLOG && $log->info('Search : ' . $search);

	my $key = uri_escape_utf8("search_${search}_${type}_") . ($args->{_dontPreCache} || 0);

	if ( my $cached = $cache->get($key) ) {
		$cb->($cached);
		return;
	}

	$args->{limit} ||= QOBUZ_DEFAULT_LIMIT;
	$args->{_ttl}  ||= QOBUZ_EDITORIAL_EXPIRY;
	$args->{query} ||= $search;
	$args->{type}  ||= $type if $type && $type =~ /(?:albums|artists|tracks|playlists)/;

	$self->_get('catalog/search', sub {
		my $results = shift;

		if ( !$args->{_dontPreCache} ) {
			$self->_precacheArtistPictures($results->{artists}->{items}) if $results && $results->{artists};

			$results->{albums}->{items} = _precacheAlbum($results->{albums}->{items}) if $results->{albums};

			$results->{tracks}->{items} = _precacheTracks($results->{tracks}->{items}) if $results->{tracks}->{items};
		}

		$cache->set($key, $results, 300);

		$cb->($results);
	}, $args);
}

#Sven 2020-03-30 new parameter $noalbums, if it is not undef, getArtist returns no extra album information.
sub getArtist {
	my ($self, $cb, $artistId, $noalbums) = @_;

	$self->_get('artist/get', sub {
		my $results = shift;

		if ( $results && (my $images = $results->{image}) ) {
			my $pic = Plugins::Qobuz::API::Common->getImageFromImagesHash($images);
			$self->_precacheArtistPictures([
				{ id => $artistId, picture => $pic }
			]) if $pic;
		}

		$results->{albums}->{items} = _precacheAlbum($results->{albums}->{items}) if $results->{albums};

		$cb->($results) if $cb;
	}, $noalbums ? { artist_id => $artistId } : { #Sven 2020-03-30 new parameter $noalbums
		artist_id => $artistId,
		extra     => 'albums',
		limit     => QOBUZ_DEFAULT_LIMIT,
	});
}

sub getLabel {
	my ($self, $cb, $labelId) = @_;

	$self->_get('label/get', sub {
		my $results = shift;

		$results->{albums}->{items} = _precacheAlbum($results->{albums}->{items}) if $results->{albums};

		$cb->($results) if $cb;
	}, {
		label_id => $labelId,
		extra     => 'albums',
		limit     => QOBUZ_DEFAULT_LIMIT,
	});
}

sub getArtistPicture {
	my ($self, $artistId) = @_;

	my $url = $cache->get('artistpicture_' . $artistId) || '';

	$self->_precacheArtistPictures([{ id => $artistId }]) unless $url;

	return $url;
}

sub getSimilarArtists {
	my ($self, $cb, $artistId) = @_;

	$self->_get('artist/getSimilarArtists', sub {
		my $results = shift;

		$self->_precacheArtistPictures($results->{artists}->{items}) if $results && $results->{artists};

		$cb->($results);
	}, {
		artist_id => $artistId,
		limit     => 100,	# max. is 100
	});
}

sub getGenres {
	my ($self, $cb, $genreId) = @_;

	my $params = {};
	$params->{parent_id} = $genreId if $genreId;

	$self->_get('genre/list', $cb, $params);
}

#Sven 2022-05-23 neuer Parameter 'extra' und eine Optimierung
sub getAlbum {
	my ($self, $cb, $args) = @_;
	#$args enthält entweder direkt die album_id oder ein Array
	#mit den Hashwerten album_id und extra
	#album_id => $albumId,
	#extra    => 'albumsFromSameArtist', 'focus','focusAll',

	
	if (! ref $args) { $args = { album_id => $args }; };

	$self->_get('album/get', sub {
		my $album = shift;
		
		if ($album) {
			#<Sven 2022-05-23
			if ($album->{albums_same_artist} && $album->{albums_same_artist}->{items}) {
				$album->{albums_same_artist}->{items} = _precacheAlbum($album->{albums_same_artist}->{items});
			}
			#>Sven
			($album) = @{_precacheAlbum([$album])};
		}

		$cb->($album);
	}, $args);
}

sub getFeaturedAlbums {
	my ($self, $cb, $type, $genreId) = @_;

	my $args = {
		type     => $type,
		limit    => QOBUZ_DEFAULT_LIMIT,
		_ttl     => QOBUZ_EDITORIAL_EXPIRY,
	};

	$args->{genre_id} = $genreId if $genreId;

	$self->_get('album/getFeatured', sub {
		my $albums = shift;

		$albums->{albums}->{items} = _precacheAlbum($albums->{albums}->{items}) if $albums->{albums};
		$cb->($albums);
	}, $args);
}

#Sven 2022-05-23 add
sub getLabelAlbums {
	my ($self, $cb, $labelid) = @_;
	
	# extra => 'albums', 'focus', 'focusAll' oder 'albums,focus'

	my $args = {
		label_id => $labelid,
		extra    => 'albums',
		limit    => QOBUZ_DEFAULT_LIMIT,
		_ttl     => QOBUZ_EDITORIAL_EXPIRY,
	};

	$self->_get('label/get', sub {
		my $label = shift;
		
		#$log->error(Data::Dump::dump($label));

		$label->{albums}->{items} = _precacheAlbum($label->{albums}->{items}) if $label->{albums};

		$cb->($label);
	}, $args);
}

sub getUserPurchases {
	my ($self, $cb, $limit) = @_;

	$self->_get('purchase/getUserPurchases', sub {
		my $purchases = shift;

		$purchases->{albums}->{items} = _precacheAlbum($purchases->{albums}->{items}) if $purchases->{albums};
		$purchases->{tracks}->{items} = _precacheTracks($purchases->{tracks}->{items}) if $purchases->{tracks};

		$cb->($purchases);
	},{
		limit    => $limit || QOBUZ_USERDATA_LIMIT,
		_ttl     => QOBUZ_USER_DATA_EXPIRY,
		_user_cache => 1,
		_use_token => 1,
	});
}

sub getUserPurchasesIds {
	my ($self, $cb) = @_;

	$self->_get('purchase/getUserPurchasesIds', sub {
		$cb->(@_) if $cb;
	},{
		_user_cache => 1,
		_use_token => 1,
	})
}

sub checkPurchase {
	my ($self, $type, $id, $cb) = @_;

	$self->getUserPurchasesIds(sub {
		my ($purchases) = @_;

		$type = $type . 's';
		if ( $purchases && ref $purchases && $purchases->{$type} && ref $purchases->{$type} && (my $items = $purchases->{$type}->{items}) ) {
			if ( $items && ref $items && scalar @$items ) {
				$cb->(
					(grep { $_->{id} =~ /^\Q$id\E$/i } @$items)
					? 1
					: 0
				);
				return;
			}
		}
		$cb->();
	});
}

#Sven 2022-05-20 new parameter $type
sub getUserFavorites {
	my ($self, $cb, $type, $force) = @_;

	$self->_pagingGet('favorite/getUserFavorites', sub {
		my ($favorites) = @_;

		$favorites->{albums}->{items} = _precacheAlbum($favorites->{albums}->{items})  if $favorites->{albums};
		$favorites->{tracks}->{items} = _precacheTracks($favorites->{tracks}->{items}) if $favorites->{tracks};

		$cb->($favorites);
	}, {
		limit => QOBUZ_USERDATA_LIMIT,
		type  => $type, #Sven - Parameter für Qobuz API 'favorite/getUserFavorites'
		_ttl       => QOBUZ_USER_DATA_EXPIRY,
		_use_token => 1,
		_wipecache => $force,
	}, $type);
}

#Sven 2022-05-13 add
sub setFavorite {
	my ($self, $cb, $args) = @_;

	my $command = 'favorite/' . ($args->{add} ? 'create' : 'delete');
	my $type = $args->{album_ids} ? 'albums' : ($args->{track_ids} ? 'tracks' : 'artists');

	delete $args->{add};
	$args->{_use_token} = 1;
	$args->{_nocache}   = 1;

	$self->_get($command, sub {
		my $result = shift;
		$self->getUserFavorites(sub{$cb->($result)}, $type, 'refresh');
	}, $args);
}

#Sven 2022-05-13 add
sub getFavoriteStatus {
	my ($self, $cb, $args) = @_; # $args = { item_id => ...., type = ...}   Accepted values for type are 'album', 'track', 'artist', 'article'

	$args->{_use_token} = 1;
	$args->{_nocache}   = 1;

	$self->_get('favorite/status', sub { $args->{status} = (shift->{status} eq JSON::XS::true()); $cb->($args); }, $args);
}

#Sven 2022-05-13 filter, 2023-10-09 einstellbare Sortierung
sub getUserPlaylists {
	my ($self, $cb, $args) = @_;
	
	$args = $args || {};
	
	my $myArgs = {
#		username => $args->{user} || Plugins::Qobuz::API::Common->username($self->userId),
		user_id  => $args->{user_id} || $self->userId, #Sven
		limit    => $args->{limit} || QOBUZ_USERDATA_LIMIT,
		_ttl     => QOBUZ_USER_DATA_EXPIRY,
		_user_cache => 1,
		_use_token => 1,
		_wipecache => $args->{force},
	};
	if ($args->{filter}) { $myArgs->{filter} = $args->{filter} };
	
	my $sort = $cb;
	
	if ($prefs->get('sortUserPlaylists') || 0 == 1) {
		$sort = sub {
			my $playlists = shift;

			$playlists->{playlists}->{items} = [ sort {
				lc($a->{name}) cmp lc($b->{name})
			} @{$playlists->{playlists}->{items} || []} ] if $playlists && ref $playlists && $playlists->{playlists} && ref $playlists->{playlists};
		
			$cb->($playlists);
		};
	};

	$self->_get('playlist/getUserPlaylists', $sort, $myArgs);

}

#Sven 2022-05-14 add
sub doPlaylistCommand {
	my ($self, $cb, $args) = @_;
	
	$self->_get('playlist/' . $args->{command}, sub {
		my $result = shift;
		$self->getUserPlaylists(sub{$cb->($result)}, { force => 'refresh'});
	}, {
		playlist_id => $args->{playlist_id},
		_use_token => 1,
		_nocache => 1
	});
}

#Sven 2022-05-23 add
sub getSimilarPlaylists {
	my ($self, $cb, $playlistId) = @_;
	
	$self->_get('playlist/get', $cb, {
		playlist_id => $playlistId,
		extra       => 'getSimilarPlaylists',
		limit    => QOBUZ_USERDATA_LIMIT,
		_ttl     => QOBUZ_USER_DATA_EXPIRY,
		_use_token => 1,
	});
}

#Sven 2024-02-18 ab hier bis zum Ende ist der Kode identisch mit der Originalversion von Michael Herger
sub getPublicPlaylists {
	my ($self, $cb, $type, $genreId, $tags) = @_;

	my $args = {
		type  => $type =~ /(?:last-created|editor-picks)/ ? $type : 'editor-picks',
		limit => QOBUZ_USERDATA_LIMIT,
		_ttl  => QOBUZ_EDITORIAL_EXPIRY,
		_use_token => 1,
	};

	$args->{genre_ids} = $genreId if $genreId;
	$args->{tags} = $tags if $tags;

	$self->_pagingGet('playlist/getFeatured', $cb, $args, 'playlists'); 
}

sub getPlaylistTracks {
	my ($self, $cb, $playlistId) = @_;

	$self->_pagingGet('playlist/get', sub {
		my $tracks = shift;

		$tracks->{tracks}->{items} = _precacheTracks($tracks->{tracks}->{items});

		$cb->($tracks);
	},{
		playlist_id => $playlistId,
		extra       => 'tracks',
		limit       => QOBUZ_USERDATA_LIMIT,
		_ttl        => QOBUZ_USER_DATA_EXPIRY,
		_use_token  => 1,
	}, 'tracks');
}

sub getTags {
	my ($self, $cb) = @_;

	$self->_get('playlist/getTags', sub {
		my $result = shift;

		my $tags = [];

		if ($result && ref $result && $result->{tags} && ref $result->{tags}) {
			$tags = [ grep {
				$_->{id} && $_->{name};
			} map {
				my $name = eval { from_json($_->{name_json}) };
				{
					featured_tag_id => $_->{featured_tag_id},
					id => $_->{slug},
					name => $name
				};
			} @{$result->{tags}} ];
		}

		$cb->($tags);
	},{
		_use_token => 1
	});
}

sub getTrackInfo {
	my ($self, $cb, $trackId) = @_;

	return $cb->() unless $trackId;

	if ($trackId =~ /^http/i) {
		$trackId = $cache->get("trackId_$trackId");
	}

	my $meta = $cache->get('trackInfo_' . $trackId);

	if ($meta) {
		$cb->($meta);
		return $meta;
	}

	$self->_get('track/get', sub {
		my $meta = shift || { id => $trackId };

		$meta = precacheTrack($meta);

		$cb->($meta);
	},{
		track_id => $trackId
	});
}

sub getFileUrl {
	my ($self, $cb, $trackId, $format, $client) = @_;

	my $maxSupportedSamplerate = min(map {
		$_->maxSupportedSamplerate
	} grep {
		$_->maxSupportedSamplerate
	} $client->syncGroupActiveMembers);

	$self->getFileInfo($cb, $trackId, $format, 'url', $maxSupportedSamplerate);
}

sub getFileInfo {
	my ($self, $cb, $trackId, $format, $urlOnly, $maxSupportedSamplerate) = @_;

	$cb->() unless $trackId;

	if ($trackId =~ /^http/i) {
		$trackId = $cache->get("trackId_$trackId");
	}

	my $preferredFormat;

	if ($format =~ /fl.c/i) {
		$preferredFormat = $prefs->get('preferredFormat');
		if ($preferredFormat < QOBUZ_STREAMING_FLAC_HIRES || ($maxSupportedSamplerate && $maxSupportedSamplerate < 48_000)) {
			$preferredFormat = QOBUZ_STREAMING_FLAC;
		}
		elsif ($preferredFormat > QOBUZ_STREAMING_FLAC_HIRES) {
			if ($maxSupportedSamplerate && $maxSupportedSamplerate <= 96_000) {
				$preferredFormat = QOBUZ_STREAMING_FLAC_HIRES;
			}
		}
	}
	elsif ($format =~ /mp3/i) {
		$preferredFormat = QOBUZ_STREAMING_MP3 ;
	}

	$preferredFormat ||= $prefs->get('preferredFormat') || QOBUZ_STREAMING_MP3;

	if ( my $cached = $self->getCachedFileInfo($trackId, $urlOnly, $preferredFormat) ) {
		$cb->($cached);
		return $cached
	}

	$self->_get('track/getFileUrl', sub {
		my $track = shift;

		if ($track) {
			my $url = delete $track->{url};

			# cache urls for a short time only
			$cache->set("trackUrl_${trackId}_${preferredFormat}", $url, URL_EXPIRY);
			$cache->set("trackId_$url", $trackId, QOBUZ_DEFAULT_EXPIRY);
			$cache->set("fileInfo_${trackId}_${preferredFormat}", $track, QOBUZ_DEFAULT_EXPIRY);
			$track = $url if $urlOnly;
		}

		$cb->($track);
	},{
		track_id   => $trackId,
		format_id  => $preferredFormat,
		_ttl       => URL_EXPIRY,
		_sign      => 1,
		_use_token => 1,
	});
}

# this call is synchronous, as it's only working on cached data
sub getCachedFileInfo {
	my ($class, $trackId, $urlOnly, $preferredFormat) = @_;

	$preferredFormat ||= $prefs->get('preferredFormat');

	if ($trackId =~ /^http/i) {
		$trackId = $cache->get("trackId_$trackId");
	}

	return $cache->get($urlOnly ? "trackUrl_${trackId}_$preferredFormat" : "fileInfo_${trackId}_$preferredFormat");
}

my @artistsToLookUp;
my $artistLookup;
sub _precacheArtistPictures {
	my ($self, $artists) = @_;

	return unless $artists && ref $artists eq 'ARRAY';

	foreach my $artist (@$artists) {
		my $key = 'artistpicture_' . $artist->{id};
		if ($artist->{picture}) {
			$cache->set($key, $artist->{picture}, -1);
		}
		elsif (!$cache->get($key)) {
			push @artistsToLookUp, $artist->{id};
		}
	}

	$self->_lookupArtistPicture() if @artistsToLookUp && !$artistLookup;
}

sub _lookupArtistPicture {
	my ($self) = @_;

	if ( !scalar @artistsToLookUp ) {
		$artistLookup = 0;
	}
	else {
		$artistLookup = 1;
		$self->getArtist(sub { $self->_lookupArtistPicture() }, shift @artistsToLookUp);
	}
}

sub _get {
	my ( $self, $url, $cb, $params ) = @_;

	# need to get a token first?
	my $token = '';

	if ($url ne 'user/login' && blessed $self) {
		$token = ($params->{_cid} || 0)
			? Plugins::Qobuz::API::Common->getWebToken($self->userId)
			: Plugins::Qobuz::API::Common->getToken($self->userId);
		if ( !$token ) {
			$log->error('No or invalid user session');
			return $cb->();
		}
	}

	$params->{user_auth_token} = $token if delete $params->{_use_token};

	$params ||= {};

	my @query;
	while (my ($k, $v) = each %$params) {
		next if $k =~ /^_/;		# ignore keys starting with an underscore
		push @query, $k . '=' . uri_escape_utf8($v);
	}

	my $appId = (delete $params->{_cid} && $cid) || $aid;
	push @query, "app_id=$appId";

	# signed requests - see
	# https://github.com/Qobuz/api-documentation#signed-requests-authentification-
	if ($params->{_sign}) {
		my $signature = $url;
		$signature =~ s/\///;

		$signature .= join('', sort map {
			my $v = $_;
			$v =~ s/=//;
			$v;
		} grep {
			$_ !~ /(?:app_id|user_auth_token)/
		} @query);

		my $ts = time;
		$signature = md5_hex($signature . $ts . $as);

		push @query, "request_ts=$ts", "request_sig=$signature";

		$params->{_nocache} = 1;
	}

	$url = QOBUZ_BASE_URL . $url . '?' . join('&', sort @query);

	if (main::INFOLOG && $log->is_info) {
		my $data = $url;
		$data =~ s/(?:$aid|$token|$cid)//g;
		$log->info($data);
	}

	my $cacheKey = $url . ($params->{_user_cache} ? $self->userId : '');

	if ($params->{_wipecache}) {
		$cache->remove($cacheKey);
	}

	if (!$params->{_nocache} && (my $cached = $cache->get($cacheKey))) {
		main::DEBUGLOG && $log->is_debug && $log->debug("found cached response: " . Data::Dump::dump($cached));
		$cb->($cached);
		return;
	}

	my %headers = (
		'X-User-Auth-Token' => $token,
		'X-App-Id' => $appId,
	);

	$headers{'User-Agent'} = ($prefs->get('useragent') || BROWSER_UA) if $appId == $cid;

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;

			my $result = eval { from_json($response->content) };

			$@ && $log->error($@);
			main::DEBUGLOG && $log->is_debug && $url !~ /getFileUrl/i && $log->debug(Data::Dump::dump($result));

			if ($result && !$params->{_nocache}) {
				if ( !($params->{album_id}) || ( $result->{release_date_stream} && $result->{release_date_stream} lt Slim::Utils::DateTime::shortDateF(time, "%Y-%m-%d") ) ) {
					$cache->set($cacheKey, $result, $params->{_ttl} || QOBUZ_DEFAULT_EXPIRY);
				}
			}

			$cb->($result);
		},
		sub {
			my ($http, $error) = @_;

			$log->warn("Error: $error");
			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($http));

			$cb->();
		},
		{
			timeout => 15,
		},
	)->get($url, %headers);
}

sub _pagingGet {
	my ( $self, $url, $cb, $params, $type ) = @_;

	return {} unless $type;

	my $limitTotal = $params->{limit};
	my $limitPage  = $params->{limit} = min($params->{limit}, QOBUZ_LIMIT);

	$self->_get($url, sub {
		my ($result) = @_;

		my $total  = $result->{$type}->{total} || QOBUZ_LIMIT;
		my $count  = $result->{$type}->{limit} || $limitPage;
		$limitPage = $params->{limit} = $count if ( $count < $limitPage );

		main::DEBUGLOG && $log->is_debug && $log->debug("Need another page? " . Data::Dump::dump({
			total => $total,
			pageSize  => $limitPage,
			requested => $limitTotal
		}));

		if ($total > $limitPage && $limitTotal > $limitPage) {
			my $pageFn = sub {
				my ($cb) = @_;
				$params->{offset} += $limitPage;
				$self->_get($url, sub {
					my ($page) = @_;
					$page = $page->{$type};
					push @{$result->{$type}->{items}}, @{$page->{items}};
					$cb->($cb) if ($page->{limit} + $page->{offset} < $page->{total});
				}, $params);
			};
			
			$pageFn->($pageFn);
		}
		$cb->($result);
	}, $params);
}

sub aid { $aid }

1;