=head Infos
Sven 2025-10-15 enhancements based on version 1.400 up to 3.6.3

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License, version 2.

 1. included a new album information menu befor playing the album
	It shows: Samplesize, Samplerate, Genre, Duration, Description if present, Goodies (Booklet) if present,
	trackcount, Credits including performers, Conductor if present, Artist, Composer, ReleaseDate, Label (with label albums),
	Copyright, add Album or Artist to your Qobuz favorites
 Enhanced Artist menu with biography, album list, title list, playlists, similar artists 
 2. added samplerate of currently streamed file in the 'More Info' menu
 3. added samplesize of currently streamed file in the 'More Info' menu
 4. shows conductor including artist information for classic albums
 5. added seeking inside flac files while playing
 6. added new preference 'FLAC 24 bits / 96 kHz (Hi-Res)'
 7. my prefered menu order in main menu
 8. added "Album Information" if MusicArtistInfo plugin is installed.
 9. added "Artist Information" if MusicArtistInfo plugin is installed.
10. added a menu for a playlist item with the playlist, duration, title count, description,
          owner (if present), genres, release date, update date, similar playlists (if present)
11. added subscribe/unsubscribe of playlist subscribtion
12. added delete my own playlists
13. added much more compatibility and useability with LMS favorites
14. added a TrackMenu, you get it if you click on a track item and select the more... menu item, 2025-03-22
15. added genre filter for user favorites, albums and playlists 2025-09-17, the previous genre menu is removed
16. added albums of the week 2025-10-15 

all changes are marked with "#Sven" in source code
changed files: Common.pm, API.pm, Plugin.pm, ProtocolHandler.pm, Settings.pm, strings.txt and basic.html from .../Qobuz/HTML/EN/plugins/Qobuz/settings/basic.html

With the value type => 'link' a list with symbols gets the option "Toggle View"
With the value type => 'playlist' a list with symbols gets the option "Toggle View" and the "ADD" and "PLAY" buttons are displayed.
It should therefore only be used for track lists (album, tracks and playlists).
Since version 3.0.7 my hack of "My weekly Q" ist included in Qobuz plugin of Pierre Beck / Michael Herger
=cut
package Plugins::Qobuz::Plugin;

use strict;
use base qw(Slim::Plugin::OPMLBased);

use JSON::XS::VersionOneAndTwo;
use Tie::RegexpHash;
use POSIX qw(strftime); #??? geht scheinbar auch ohne

use Slim::Formats::RemoteMetadata;
use Slim::Player::ProtocolHandlers;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);
use Scalar::Util qw(looks_like_number);

use Plugins::Qobuz::API;
use Plugins::Qobuz::API::Common;
use Plugins::Qobuz::ProtocolHandler;
use Plugins::Qobuz::Addon;

use constant CAN_IMPORTER => (Slim::Utils::Versions->compareVersions($::VERSION, '8.0.0') >= 0);
use constant CLICOMMAND => 'qobuzquery';
use constant MAX_RECENT => 30;

use constant ALBUM => '1';
use constant EP => '2';
use constant SINGLE => '3';

# Keep in sync with Music & Artist Information plugin
my $WEBLINK_SUPPORTED_UA_RE = qr/\b(?:iPeng|SqueezePad|OrangeSqueeze|OpenSqueeze|Squeezer|Squeeze-Control)\b/i;
my $WEBBROWSER_UA_RE = qr/\b(?:FireFox|Chrome|Safari)\b/i;

my $GOODIE_URL_PARSER_RE = qr/\.(?:pdf|png|gif|jpg)$/i;

my $prefs = preferences('plugin.qobuz');

tie my %localizationTable, 'Tie::RegexpHash';

%localizationTable = (
	qr/^Livret Num.rique/i => 'PLUGIN_QOBUZ_BOOKLET'
);

my $IsMusicArtistInfo = 0; #Sven

$prefs->init({
	accounts => {},
	preferredFormat => 6,
	filterSearchResults => 0,
	playSamples => 1,
	dontImportPurchases => 1,
	classicalGenres => '',
	useClassicalEnhancements => 1,
	parentalWarning => 0,
	showDiscs => 0,
	groupReleases => 1,
	importWorks => 1,
	sortPlaylists => 1,
	showUserPurchases => 1,
	genreFilter => '##',
	genreFavsFilter => '##',
	sortArtistsAlpha => 1
});

$prefs->migrate(1,
	sub {
		my $token = $prefs->get('token');
		my $userdata = $prefs->get('userdata');

		# migrate existing account to new list of accounts
		if ($token && $userdata && (my $id = $userdata->{id})) {
			my $accounts = $prefs->get('accounts') || {};
			$accounts->{$id} = {
				token => $token,
				userdata => $userdata,
			};
		}

		$prefs->remove('token', 'userdata', 'userinfo', 'username');
		1;
	}
);

# reset the API ref when a player changes user
$prefs->setChange( sub {
	my ($pref, $userId, $client) = @_;
	$client->pluginData(api => 0);
}, 'userId');

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.qobuz',
	defaultLevel => 'ERROR',
	description  => 'PLUGIN_QOBUZ',
	logGroups    => 'SCANNER',
} );

use constant PLUGIN_TAG => 'qobuz';
use constant CAN_IMAGEPROXY => (Slim::Utils::Versions->compareVersions($::VERSION, '7.8.0') >= 0);

my $cache = Plugins::Qobuz::API::Common->getCache();

#Sven 2022-05-10
sub initPlugin {
	my $class = shift;

	if (main::WEBUI) {
		require Plugins::Qobuz::Settings;
		Plugins::Qobuz::Settings->new();
	}

	Plugins::Qobuz::API->init(
		$class->_pluginDataFor('aid')
	);

	Slim::Player::ProtocolHandlers->registerHandler(
		qobuz => 'Plugins::Qobuz::ProtocolHandler'
	);

	Slim::Formats::Playlists->registerParser('qbz', 'Plugins::Qobuz::PlaylistParser');

	Slim::Player::ProtocolHandlers->registerIconHandler(
		qr|\.qobuz\.com/|,
		sub { $class->_pluginDataFor('icon') }
	);

	# Track Info item
	Slim::Menu::TrackInfo->registerInfoProvider( qobuzTrackInfo => (
		func  => \&trackInfoMenu,
	) );

	Slim::Menu::ArtistInfo->registerInfoProvider( qobuzArtistInfo => (
		func  => \&artistInfoMenu
	) );

	Slim::Menu::AlbumInfo->registerInfoProvider( qobuzAlbumInfo => (
		func  => \&albumInfoMenu
	) );

	Slim::Menu::GlobalSearch->registerInfoProvider( qobuzSearch => (
		func => \&searchMenu
	) );

	#Sven 2022-05-10 
	Slim::Menu::PlaylistInfo->registerInfoProvider( qobuzPlaylistInfo => (
		#after => 'playitem',
		func => \&albumInfoMenu
	) );

	#                                                          |requires Client
	#                                                          |  |is a Query
	#                                                          |  |  |has Tags
	#                                                          |  |  |  |Function to call
	#                                                          C  Q  T  F
	Slim::Control::Request::addDispatch(['qobuz', 'goodies'], [1, 1, 1, \&_getGoodiesCLI]);

	Slim::Control::Request::addDispatch(['qobuz', 'playalbum'], [1, 0, 0, \&cliQobuzPlayAlbum]);
	Slim::Control::Request::addDispatch(['qobuz', 'addalbum'], [1, 0, 0, \&cliQobuzPlayAlbum]);
	Slim::Control::Request::addDispatch(['qobuz','recentsearches'],[1, 0, 1, \&_recentSearchesCLI]);

	# "Local Artwork" requires LMS 7.8+, as it's using its imageproxy.
	if (CAN_IMAGEPROXY) {
		require Slim::Web::ImageProxy;
		Slim::Web::ImageProxy->registerHandler(
			match => qr/static\.qobuz\.com/,
			func  => \&_imgProxy,
		);
	}

	if (CAN_IMPORTER) {
		# tell LMS that we need to run the external scanner
		Slim::Music::Import->addImporter('Plugins::Qobuz::Importer', { use => 1 });
	}

	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => PLUGIN_TAG,
		menu   => 'radios',
		is_app => 1,
		weight => 1,
	);
}

#Sven
sub postinitPlugin {
	my $class = shift;

	if ( Slim::Utils::PluginManager->isEnabled('Plugins::LastMix::Plugin') ) {
		eval {
			require Plugins::LastMix::Services;
		};

		if (!$@) {
			main::INFOLOG && $log->info("LastMix plugin is available - let's use it!");
			require Plugins::Qobuz::LastMix;
			Plugins::LastMix::Services->registerHandler('Plugins::Qobuz::LastMix', 'lossless');
		}
	}

	if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::OnlineLibrary::Plugin') ) {
		Slim::Plugin::OnlineLibrary::Plugin->addLibraryIconProvider('qobuz', '/plugins/Qobuz/html/images/icon.png');

		Slim::Plugin::OnlineLibrary::BrowseArtist->registerBrowseArtistItem( qobuz => sub {
			my ( $client ) = @_;

			return {
				name => cstring($client, 'BROWSE_ON_SERVICE', 'Qobuz'),
				type => 'link',
				icon => $class->_pluginDataFor('icon'),
				url  => \&browseArtistMenu,
			};
		} );

		main::INFOLOG && $log->is_info && $log->info("Successfully registered BrowseArtist handler for Qobuz");
	}
	
	#Sven
	if ( Slim::Utils::PluginManager->isEnabled('Plugins::MusicArtistInfo::Plugin') ) {
		eval {
			require Plugins::MusicArtistInfo::AlbumInfo;
			require Plugins::MusicArtistInfo::ArtistInfo;
		};
		$IsMusicArtistInfo = 1;
	}

}

sub onlineLibraryNeedsUpdate {
	if (CAN_IMPORTER) {
		my $class = shift;
		require Plugins::Qobuz::Importer;
		return Plugins::Qobuz::Importer->needsUpdate(@_);
	}
	else {
		$log->warn('The library importer feature requires at least Logitech Media Server 8');
	}
}

sub getLibraryStats { if (CAN_IMPORTER) {
	require Plugins::Qobuz::Importer;
	my $totals = Plugins::Qobuz::Importer->getLibraryStats();
	return wantarray ? ('PLUGIN_QOBUZ', $totals) : $totals;
} }

sub getDisplayName { 'PLUGIN_QOBUZ' }

# don't add this plugin to the Extras menu
sub playerMenu {}

#Sven 2024-01-24 
sub handleFeed {
	my ($client, $cb, $args) = @_;

	if ( !Plugins::Qobuz::API::Common->hasAccount() ) {
		return $cb->({
			items => [{
				name => cstring($client, 'PLUGIN_QOBUZ_REQUIRES_CREDENTIALS'),
				type => 'textarea',
			}]
		});
	}

	my $params = $args->{params};

	my $items = [{
		name  => cstring($client, 'SEARCH'),
		image => 'html/images/search.png',
		type => 'link',
		url  => sub {
			my ($client, $cb, $params) = @_;
			my $items = [];

			my $i = 0;
			for my $recent ( @{ $prefs->get('qobuz_recent_search') || [] } ) {
				unshift @$items, {
					name  => $recent,
					type  => 'link',
					url  => sub {
						my ($client, $cb, $params) = @_;
						my $menu = searchMenu($client, {
							search => lc($recent)
						});
						$cb->({
							items => $menu->{items}
						});
					},
					itemActions => {
						info => {
							command     => ['qobuz', 'recentsearches'],
							fixedParams => { deleteMenu => $i++ },
						},
					},
					passthrough => [ { type => 'search' } ],
				};
			}

			unshift @$items, {
				name  => cstring($client, 'PLUGIN_QOBUZ_NEW_SEARCH'),
				type  => 'search',
				url  => sub {
					my ($client, $cb, $params) = @_;
					addRecentSearch($params->{search});
					my $menu = searchMenu($client, {
						search => lc($params->{search})
					});
					$cb->({
						items => $menu->{items}
					});
				},
				passthrough => [ { type => 'search' } ],
			};

			$cb->({ items => $items });
		},
	},{
#Sven - ab hier angepasst
		name  => cstring($client, 'PLUGIN_QOBUZ_USER_FAVORITES'),
		image => 'html/images/favorites.png',
		type  => 'menu', #Sven - view type
		items => [{
			name  => cstring($client, 'PLUGIN_QOBUZ_GENRE_SELECT'),
			image => 'html/images/genres.png',
			type  => 'menu', #Sven - view type
			url  => \&QobuzGenreSelection,
			passthrough => [{ filter => 'genreFavsFilter' }],
			}, {
			name  => cstring($client, 'ALBUMS'),
			image => 'html/images/albums.png',
			url   => \&QobuzUserFavorites,
			type  => 'albums', #Sven - view type
			passthrough => ['albums'],
			}, {
			name  => cstring($client, 'SONGS'),
			image => 'html/images/playlists.png',
			type  => 'playlist',
			url   => \&QobuzUserFavorites,
			passthrough => ['tracks'],
			}, {
			name  => cstring($client, 'ARTISTS'),
			image => 'html/images/artists.png',
			type  => 'artists', #Sven - view type
			url   => \&QobuzUserFavorites,
			passthrough => ['artists'],
			}
		],
	},{
		name => cstring($client, 'PLUGIN_QOBUZ_ALBUM_PICKS'),
		image => 'html/images/albums.png',
		type  => 'menu', #Sven - view type
		url  => \&QobuzAlbums,
		passthrough => [{ genreId => '' }]
	},{
		name => cstring($client, 'PLUGIN_QOBUZ_PUBLICPLAYLISTS'),
		url  => \&QobuzPlaylistTags,
		type  => 'menu', #Sven - view type
		image => 'html/images/playlists.png',
		passthrough => [{ }]
	},{
		name => cstring($client, 'PLUGIN_QOBUZ_USERPLAYLISTS'),
		type  => 'playlists', #Sven - view type
		url  => \&QobuzUserPlaylists,
		image => 'html/images/playlists.png'
	},{
		name => cstring($client, 'PLUGIN_QOBUZ_MYWEEKLYQ'),
		type  => 'link',
		url  => \&QobuzMyWeeklyQ,
		image => 'html/images/playlists.png'
	}];
	
	push @$items, {
		name => cstring($client, 'PLUGIN_QOBUZ_USERPURCHASES'),
		type  => 'link',
		url  => \&QobuzUserPurchases,
		image => 'html/images/albums.png'
	} if ($prefs->get('showUserPurchases'));
	
	if ($client && scalar @{ Plugins::Qobuz::API::Common::getAccountList() } > 1) {
		push @$items, {
			name => cstring($client, 'PLUGIN_QOBUZ_SELECT_ACCOUNT'),
			image => __PACKAGE__->_pluginDataFor('icon'),
			url => \&QobuzSelectAccount,
		};
	}
	
	$cb->({
		items => $items
	});
}

sub QobuzSelectAccount {
	my $cb = $_[1];

	my $items = [ map {
		{
			name => $_->[0],
			url => sub {
				my ($client, $cb2, $params, $args) = @_;

				$client->pluginData(api => 0);
				$prefs->client($client)->set('userId', $args->{id});

				$cb2->({ items => [{
					nextWindow => 'grandparent',
				}] });
			},
			passthrough => [{
				id => $_->[1]
			}],
			nextWindow => 'parent'
		}
	} @{ Plugins::Qobuz::API::Common->getAccountList() } ];

	$cb->({ items => $items });
}

#Sven 2022-05-20
sub QobuzMyWeeklyQ {
	my ($client, $cb, $params) = @_;

	if (Plugins::Qobuz::API::Common->getToken($client) && !Plugins::Qobuz::API::Common->getWebToken($client)) {
		return QobuzGetWebToken(@_);
	}

	getAPIHandler($client)->getMyWeekly(sub {
		my $myWeekly = shift;

		if (!$myWeekly) {
			$log->error("Get MyWeekly ($myWeekly) failed");
			$cb->();
			return;
		}

		my $tracks = [];

		foreach my $track (@{$myWeekly->{tracks}->{items} || []}) {
			push @$tracks, _trackItem($client, $track, 1); #Sven  $params->{isWeb}
		}
		
		my $items = []; #ref array
		
		push @$items, {
			name  => $myWeekly->{title},
			name2 => $myWeekly->{baseline},
			image => $myWeekly->{images}->{large},
			type  => 'playlist',
			items => $tracks,
		};
		
		push @$items, {
			name => $myWeekly->{track_count} . ' ' . cstring($client, ($myWeekly->{tracks_count} eq 1 ? 'PLUGIN_QOBUZ_TRACK' : 'PLUGIN_QOBUZ_TRACKS')) . ' - ' . cstring($client, 'LENGTH') . ' ' . _sec2hms($myWeekly->{duration}),
			type => 'text'
		};
		
		push @$items, { name => cstring($client, 'PLUGIN_QOBUZ_RELEASED_AT') . cstring($client, 'COLON') . ' ' . Slim::Utils::DateTime::shortDateF($myWeekly->{generated_at}), type  => 'text' } if $myWeekly->{generated_at};
		
		if ($myWeekly->{description}) {
			push @$items, {
				name  => cstring($client, 'DESCRIPTION'),
				items => [{ name => _stripHTML($myWeekly->{description}), type => 'textarea'}],
			};
		}
		
		$cb->({ items => $items });  
	});
}

sub QobuzGetWebToken {
	my ($client, $cb, $params) = @_;

	my $username = Plugins::Qobuz::API::Common->username($client);

	return $cb->({ items => [{
		type => 'textarea',
		name => cstring($client, 'PLUGIN_QOBUZ_REAUTH_DESC'),
	},{
		name  => sprintf('%s (%s)', cstring($client, 'PLUGIN_QOBUZ_PREFS_PASSWORD'), $username),
		type  => 'search',
		url  => sub {
			my ($client, $cb, $params) = @_;

			getAPIHandler($client)->login($username, $params->{search}, sub {
				my $success = shift;

				$cb->({ items => [ $success
					? {
						name => cstring($client, 'SETUP_CHANGES_SAVED'),
						nextWindow => 'home',
					}
					: {
						name => cstring($client, 'PLUGIN_QOBUZ_AUTH_FAILED'),
						nextWindow => 'parent',
					}
				] });
			},{
				cid => 1,
				token => 'success',
			});
		},
		passthrough => [ { type => 'search' } ],
	}] });
}

#Sven 2022-05-18, 2025-09-17 v30.6.2
sub QobuzAlbums {
	my ($client, $cb, $params, $args) = @_;
	
	my $genreId = $args->{genreId} || '';
	
	my @types = (
		['new-releases',		'PLUGIN_QOBUZ_NEW_RELEASES'],
		['ideal-discography',	'PLUGIN_QOBUZ_IDEAL_DISCOGRAPHY'],
		['most-streamed',		'PLUGIN_QOBUZ_MOST_STREAMED'],
		['qobuzissims',			'PLUGIN_QOBUZ_QOBUZISSIMS'],
		['albumOfTheWeek',		'PLUGIN_QOBUZ_ALBUMS_OF_THE_WEEK'], #Sven 2025-10-15 - albums of the week
		['press-awards',		'PLUGIN_QOBUZ_PRESS'],
		['editor-picks',		'PLUGIN_QOBUZ_EDITOR_PICKS'],
		['best-sellers',		'PLUGIN_QOBUZ_BESTSELLERS'],
		['most-featured',		'PLUGIN_QOBUZ_MOST_FEATURED'],
		['new-releases-full',	'PLUGIN_QOBUZ_NEW_RELEASES_FULL'],
		#['recent-releases',	'PLUGIN_QOBUZ_RECENT_RELEASES'],
		#['re-release-of-the-week',	're-release-of-the-week'],
		#['harmonia-mundi',		'harmonia-mundi'],
		#['universal-classic',	'universal-classic'],
		#['universal-jazz',		'universal-jazz'],
		#['universal-jeunesse',	'universal-jeunesse'],
		#['universal-chanson',	'universal-chanson'],
	);
	
	my $items = [];
	
	#Sven 2025-09-17
	push @$items, {
		name  => cstring($client, 'PLUGIN_QOBUZ_GENRE_SELECT'),
		image => 'html/images/genres.png',
		type  => 'menu', #Sven - view type
		url  => \&QobuzGenreSelection,
		passthrough => [{ filter => 'genreFilter' }],
	} unless ($genreId);
	
	foreach (@types) { 
		push @$items, {
			name => cstring($client, $$_[1]),
			url  => ($$_[0] eq 'albumOfTheWeek') ? \&QobuzDiscover : \&QobuzFeaturedAlbums, #Sven 2025-10-15 - albums of the week
			image => 'html/images/albums.png',
			type  => 'albums', #Sven - view type
			passthrough => [{ genreId => $genreId, type => $$_[0] }]
		};
	};
	
	$cb->({ items => $items });
}

#Sven 2024-12-15
sub QobuzSearch {
	my ($client, $cb, $params, $args) = @_;

	$args ||= {};
	$params->{search} ||= $args->{q};
	my $type   = lc($args->{type} || '');
	my $search = lc($params->{search});
	
	unless ($type) {
		my $menu = searchMenu($client, { search => $search });
		$cb->({ items => $menu->{items} });
		return;
	};
	
	getAPIHandler($client)->search(sub {
		my $searchResult = shift;

		if (!$searchResult) {
			$cb->();
			return;
		}

		my $albums = getReleases( $client, $searchResult->{albums}, $args->{artistId} );
		#my $albums = [];
		#for my $album ( @{$searchResult->{albums}->{items} || []} ) {
		#	# XXX - unfortunately the album results don't return the artist's ID
		#	next if $args->{artistId} && !($album->{artist} && lc($album->{artist}->{name}) eq $search);
		#	push @$albums, _albumItem($client, $album);
		#}

		my $artists = [];
		for my $artist ( @{$searchResult->{artists}->{items} || []} ) {
			push @$artists, _artistItem($client, $artist, 1);
		}

		my $tracks = [];
		for my $track ( @{$searchResult->{tracks}->{items} || []} ) {
			next if $args->{artistId} && !($track->{performer} && $track->{performer}->{id} eq $args->{artistId});
			push @$tracks, _trackItem($client, $track, $params->{isWeb});
		}

		my $playlists = [];
		for my $playlist ( @{$searchResult->{playlists}->{items} || []} ) {
			next if defined $playlist->{tracks_count} && !$playlist->{tracks_count};
			push @$playlists, _playlistItem($playlist, 'show-owner', $params->{isWeb});
		}

		my $items = [];

		push @$items, {
			#name  => $prefs->get('groupReleases') ? cstring($client, 'PLUGIN_QOBUZ_RELEASES') : cstring($client, 'ALBUMS'),
			name  => cstring($client, 'PLUGIN_QOBUZ_RELEASES'),
			items => $albums,
			image => 'html/images/albums.png',
			type  => 'albums', #Sven - view type
		} if scalar @$albums;

		push @$items, {
			name  => cstring($client, 'ARTISTS'),
			items => $artists,
			image => 'html/images/artists.png',
			type  => 'artists', #Sven - view type
		} if scalar @$artists;

		push @$items, {
			name  => cstring($client, 'SONGS'),
			items => $tracks,
			image => 'html/images/playlists.png',
			type  => 'playlist',
		} if scalar @$tracks;

		push @$items, {
			name  => cstring($client, 'PLAYLISTS'),
			items => $playlists,
			image => 'html/images/playlists.png',
			type  => 'playlists', #Sven - view type
		} if scalar @$playlists;

		if (scalar @$items == 1) {
			$items = $items->[0]->{items};
		}

		$cb->({
			items => $items
		});
	}, $search, $type);
}

#Sven 2024-12-14 (war bis 3.5.4 Teil von sub QobuzArtist)
sub getReleases {
	my ($client, $results, $artistID) = @_;
	
	my $releases = [];
	
	if ($results) {
		my $albums = [];
		my $numAlbums = 0;
		my $eps = [];
		my $numEps = 0;
		my $singles = [];
		my $numSingles = 0;
		
		my $groupByReleaseType = $prefs->get('groupReleases');
		# group by release type if requested
		if ($groupByReleaseType) {
			for my $album ( @{$results->{items}} ) {
				next if $artistID && $album->{artist}->{id} != $artistID;
				if ($album->{duration} >= 1800 || $album->{tracks_count} > 6) {
					$album->{release_type} = ALBUM;
					$numAlbums++;
				} elsif ($album->{tracks_count} < 4) {
					$album->{release_type} = SINGLE;
					$numSingles++;
				} else {
					$album->{release_type} = EP;
					$numEps++;
				}
			}
		}

		# sort by release date if requested
		my $sortByDate = $prefs->get('sortArtistAlbums');

		$results->{items} = [ sort {
			if ($sortByDate) {
				return $sortByDate == 1 ? ( $a->{release_type} cmp $b->{release_type} || $b->{released_at}*1 <=> $a->{released_at}*1 )
										: ( $a->{release_type} cmp $b->{release_type} || $a->{released_at}*1 <=> $b->{released_at}*1 );
			}
			else {
				return $a->{release_type} cmp $b->{release_type} || lc($a->{title}) cmp lc($b->{title});
			}

		} @{$results->{items} || []} ];

		my $lastReleaseType = "";

		for my $album ( @{$results->{items}} ) {
			next if $artistID && $album->{artist}->{id} != $artistID;
			#push @$albums, _albumItem($client, $album);
			if ($groupByReleaseType) {
				if ($album->{release_type} eq ALBUM) {
					push @$albums, _albumItem($client, $album);
				} elsif ($album->{release_type} eq EP) {
					push @$eps, _albumItem($client, $album);
				} elsif ($album->{release_type} eq SINGLE) {
					push @$singles, _albumItem($client, $album);
				}

				if ($album->{release_type} ne $lastReleaseType) {
					$lastReleaseType = $album->{release_type};
					my $relType = "";
					my $relNum = 0;
					my $relItems;
					my $relIcon = "";

					if ($lastReleaseType eq ALBUM) {
						$relType = cstring($client, 'ALBUMS');
						$relNum = $numAlbums;
						$relItems = $albums;
						$relIcon = 'plugins/Qobuz/html/images/Qobuz_MTL_svg_release-album.png';
					} elsif ($lastReleaseType eq EP) {
						$relType = cstring($client, 'RELEASE_TYPE_EPS');
						$relNum = $numEps;
						$relItems = $eps;
						$relIcon = 'plugins/Qobuz/html/images/Qobuz_MTL_svg_release-ep.png';
					} elsif ($lastReleaseType eq SINGLE) {
						$relType = cstring($client, 'RELEASE_TYPE_SINGLES');
						$relNum = $numSingles;
						$relItems = $singles;
						$relIcon = 'plugins/Qobuz/html/images/Qobuz_MTL_svg_release-single.png';
					} else {
						$relType = "Unknown";  #should never occur
					}

					push @$releases, {
						name => "$relType ($relNum)",
						image => $relIcon,	
						type => 'header',
						playall => 1,
						items => $relItems
					};
				}
			}
			push @$releases, _albumItem($client, $album);
		}
	}
	return $releases;
}

sub browseArtistMenu {
	my ($client, $cb, $params, $args) = @_;

	my $artistId = $params->{artist_id} || $args->{artist_id};
	if ( defined($artistId) && $artistId =~ /^\d+$/ && (my $artistObj = Slim::Schema->resultset("Contributor")->find($artistId))) {
		if (my ($extId) = grep /qobuz:artist:(\d+)/, @{$artistObj->extIds}) {
			($args->{artistId}) = $extId =~ /qobuz:artist:(\d+)/;
			return QobuzArtist($client, $cb, undef, { artistId => $args->{artistId} });
		}
		else {
			$args->{q}    = $artistObj->name;
			$args->{type} = 'artists';

			QobuzSearch($client, sub {
				my $items = shift || { items => [] };

				my $id;
				if (scalar @{$items->{items}} == 1) {
					$id = $items->{items}->[0]->{passthrough}->[0]->{artistId};
				}
				else {
					my @ids;
					$items->{items} = [ map {
						push @ids, $_->{passthrough}->[0]->{artistId};
						$_;
					} grep {
						Slim::Utils::Text::ignoreCase($_->{name} ) eq $artistObj->namesearch
					} @{$items->{items}} ];

					if (scalar @ids == 1) {
						$id = shift @ids;
					}
				}

				if ($id) {
					$args->{artistId} = $id;
					return QobuzArtist($client, $cb, $params, $args);
				}

				$cb->($items);
			}, $params, $args);

			return;
		}
	}

	$cb->([{
		type  => 'text',
		title => cstring($client, 'EMPTY'),
	}]);
}

#Sven 2020-03-27
sub QobuzArtist {
	my ($client, $cb, $params, $args) = @_;

	my $api = getAPIHandler($client);

	$api->getArtist(sub {
		my $artist = shift;

		if ($artist->{status} && $artist->{status} =~ /error/i) {
			$cb->();
			return;
		}

		my $items = [];
		
		if ($artist->{biography}) {
			push @$items, {
				name  => cstring($client, 'PLUGIN_QOBUZ_BIOGRAPHY'),
				image => Plugins::Qobuz::API::Common->getImageFromImagesHash($artist->{image}) || $api->getArtistPicture($artist->{id}) || 'html/images/artists.png',
				items => [{
					name => _stripHTML($artist->{biography}->{content}), # $artist->{biography}->{summary} ||
					type => 'textarea',
				}],
			}
		}
		#Sven
		else {
			push @$items, {
				name  => $artist->{name},
				image => $api->getArtistPicture($artist->{id}) || 'html/images/artists.png',
				type  => 'text'
			}
		}	

		push @$items, {
			#name  => $prefs->get('groupReleases') ? cstring($client, 'PLUGIN_QOBUZ_RELEASES') : cstring($client, 'ALBUMS'),
			name  => cstring($client, 'PLUGIN_QOBUZ_RELEASES'),
			# placeholder URL - please see below for albums returned in the artist query
			url   => \&QobuzSearch,
			image => 'html/images/albums.png',
			type  => 'albums', #Sven - view type
			passthrough => [{
				q        => $artist->{name},
				type     => 'albums',
				artistId => $artist->{id},
			}]
		};

		push @$items, {
			name  => cstring($client, 'SONGS'),
			url   => \&QobuzSearch,
			image => 'html/images/playlists.png',
			type  => 'playlist',
			passthrough => [{
				q        => $artist->{name},
				type     => 'tracks',
				artistId => $artist->{id},
			}]
		};

		my $releases = getReleases($client, $artist->{albums}, $args->{artistId});
		
		if (@$releases) {
			$items->[1]->{items} = $releases;
			delete $items->[1]->{url};
		}

		#Sven 2020-03-13
		push @$items, {	name  => cstring($client, 'PLAYLISTS'),
			url   => \&QobuzSearch,
			image => 'html/images/playlists.png',
			type  => 'playlists', #Sven - view type
			passthrough => [{
				q        => $artist->{name},
				type     => 'playlists',
				artistId => $artist->{id},
			}],
		};
		
		push @$items, {
			name => cstring($client, 'PLUGIN_QOBUZ_SIMILAR_ARTISTS'),
			image => 'html/images/artists.png',
			type  => 'artists', #Sven - view type
			url => sub {
				my ($client, $cb, $params, $args) = @_;

				$api->getSimilarArtists(sub {
					my $searchResult = shift;
		
					if (! $searchResult) { $cb->(); return;} #2020-03-21 Sven

					my $items = [];

					for my $artist ( @{$searchResult->{artists}->{items}} ) {
						push @$items, _artistItem($client, $artist, 1);
					}

					$cb->( {
						items => $items
					} );
				}, $args->{artistId});
			},
			passthrough => [{
				artistId  => $artist->{id},
			}],
		};

		if ($IsMusicArtistInfo) { # && $params) {  #Sven 2020-04-07 && $params is undef if it is called from browseArtistMenu() because of display error in Material Skin "Artist-Information - Pictures" when called from OnlineLibrary
			push @$items, {
				name  => cstring($client, 'PLUGIN_MUSICARTISTINFO_ARTISTINFO'),
				image => 'html/images/artists.png',
				type  => 'menu', #Sven - view type
				#type  => 'link',
				#use ArtistInfo::getArtistMenu() and not ArtistInfo->getArtistMenu() to pass $client as first parameter. 
				items => Plugins::MusicArtistInfo::ArtistInfo::getArtistMenu($client, undef, { artist => $artist->{name} })
			}
		}

		#Sven 2020-03-30
		push @$items, {
			name => cstring($client, 'PLUGIN_QOBUZ_MANAGE_FAVORITES'),
			image => 'html/images/favorites.png',
			type => 'menu', #'link',
			url  => \&QobuzManageFavorites,
			passthrough => [{artistId => $artist->{id}, artist => $artist->{name}}]
		};

		$cb->( {
			items => $items
		} );
	}, $args->{artistId}, 1);
}

#Sven 2025-09-15 v30.6.2
sub QobuzGenreSelection {
	my ($client, $cb, $params, $args) = @_;

	my $genreId = ''; $args->{genreId} || '';
	my $genreFilter = $args->{filter};
	
	getAPIHandler($client)->getGenres(sub {
		my $genres = shift;

		if (!$genres) {
			$log->error("Get genres failed");
			return;
		}

		my $items = [];

		push @$items, {
			name => cstring($client, 'PLUGIN_QOBUZ_GENRE_SELECTALL'),
			image => 'html/images/genres.png',
			url => \&QobuzGenreToggle,
			passthrough => [{ genreId => '', filter => $genreFilter }],
			nextWindow => 'refresh',
		};

		for my $genre ( @{$genres->{genres}->{items}}) {
			push @$items, { 
				name => $genre->{name},
				image => _isGenreSet($genre->{id}, $genreFilter) ? 'plugins/Qobuz/html/images/checkbox-checked_svg.png' : 'plugins/Qobuz/html/images/checkbox-empty_svg.png',
				url => \&QobuzGenreToggle,
				passthrough => [{ genreId => $genre->{id}, filter => $genreFilter }],
				#type => 'link', #Sven
				nextWindow => 'refresh',
			};
		}

		$cb->({
			items => $items
		})
	}, $genreId);
}

#Sven 2025-09-15
sub _isGenreSet {
	my ($genreId, $Filter) = @_;
	
	my $genreFilter = $prefs->get($Filter) || '##';
	my $result = 1;
	
	unless ($genreFilter eq '##') { 
		$genreId = '#' . $genreId . '#';
		$result = 0 unless ($genreFilter=~/$genreId/);
	}
	return $result;
}

#Sven 2025-09-16
sub _getGenres {
	my ($filter) = @_;
	
	unless ($filter) { $filter = 'genreFilter'};
	my $genreFilter = $prefs->get($filter) || '##';
	
	$genreFilter = substr($genreFilter, 1, length($genreFilter)-2);
	$genreFilter=~s/##/,/g;
	
	return $genreFilter;
}

#Sven 2025-09-17
sub QobuzGenreToggle {
	my ($client, $cb, $params, $args) = @_;

	my $genreId = $args->{genreId} || '';
	my $genreFilter = $prefs->get($args->{filter}) || '##';

	$genreId = '#' . $genreId . '#';
	if ($genreFilter eq '##' || $genreId eq '##') { $genreFilter = $genreId; }
	else {
		unless ($genreFilter=~s/$genreId//) { $genreFilter .= $genreId; }
	};
	$prefs->set($args->{filter}, $genreFilter);

	$cb->();
}

sub QobuzFeaturedAlbums {
	my ($client, $cb, $params, $args) = @_;
	my $type    = $args->{type};
	my $genreId = $args->{genreId};
	
	unless ($genreId) { $genreId = _getGenres(); }; #Sven 2025-09-16 v30.6.2
	
	getAPIHandler($client)->getFeaturedAlbums(sub {
		my $albums = shift;

		my $items = [];

		foreach my $album ( @{$albums->{albums}->{items}} ) {
			push @$items, _albumItem($client, $album);
		}

		$cb->({
			items => $items
		})
	}, $type, $genreId);
}

#Sven 2025-10-15 - albums of the week
sub QobuzDiscover {
	my ($client, $cb, $params, $args) = @_;
	my $type    = $args->{type};
	my $genreId = $args->{genreId};
	
	unless ($genreId) { $genreId = _getGenres(); }; #Sven 2025-09-16 v30.6.2
	
	if (Plugins::Qobuz::API::Common->getToken($client) && !Plugins::Qobuz::API::Common->getWebToken($client)) {
		return QobuzGetWebToken(@_);
	}
	
	getAPIHandler($client)->getDiscover(sub {
		my $albums = shift;

		my $items = [];

		foreach my $album ( @{$albums->{items}} ) {
			push @$items, _albumItem($client, $album);
		}

		$cb->({
			items => $items
		})
	}, $type, $genreId);
}

#Sven 2022-05-23 - Wurde von Michael Herger ab 3.2.0 übernommen und von QobuzLabelAlbums nach QobuzLabel umbenannt
sub QobuzLabel {
	my ($client, $cb, $params, $args) = @_;
	my $labelId = $args->{labelId};

	getAPIHandler($client)->getLabel(sub {
		my $albums = shift;

		my $items = [];

		foreach my $album ( @{$albums->{albums}->{items}} ) {
			push @$items, _albumItem($client, $album);
		}

		$cb->({
			items => $items
		})
	}, $labelId);
}

sub QobuzUserPurchases {
	my ($client, $cb, $params, $args) = @_;

	getAPIHandler($client)->getUserPurchases(sub {
		my $searchResult = shift;

		my $items = [];

		for my $album ( @{$searchResult->{albums}->{items}} ) {
			push @$items, _albumItem($client, $album);
		}

		for my $track ( @{$searchResult->{tracks}->{items}} ) {
			push @$items, _trackItem($client, $track, 1);
		}

		$cb->( {
			items => $items
		} );
	});
}

#Sven 2022-05-20, 2023-02-11 v2.8.1, 2025-09-17 v30.6.2 filtern nach Genre
sub QobuzUserFavorites {
	my ($client, $cb, $params, $type) = @_;

	getAPIHandler($client)->getUserFavorites(sub {
		my $favorites = shift;
		
		my $genreFilter = 'genreFavsFilter';
		my $items = [];
		my @aItem = @{$favorites->{$type}->{items}};
		if (scalar @aItem) {
			my $itemFn = ($type eq 'albums') ? \&_albumItem : ($type eq 'tracks') ? \&_trackItem : \&_artistItem;
			foreach ( @aItem ) {
				my $push = 1;
				if ($type eq 'albums') { $push = _isGenreSet($_->{genrePath}[0], $genreFilter) }
				elsif ($type eq 'tracks') { $push = _isGenreSet($_->{album}->{genre}->{path}[0], $genreFilter) }
				push @$items, $itemFn->($client, $_, 1) if $push;
			};

			my $sortFavsAlphabetically = ($type eq 'artists' && $prefs->get('sortArtistsAlpha')) ? 1 : $prefs->get('sortFavsAlphabetically') || 0;
			if ( $sortFavsAlphabetically ) {
				my $sortFields = { albums => ['line1', 'name'], artists => ['name', 'name'], tracks => ['line1', 'line2'] };
				my $sortField  = $sortFields->{$type}[$sortFavsAlphabetically - 1];
				@$items = sort { Slim::Utils::Text::ignoreCaseArticles($a->{$sortField}) cmp Slim::Utils::Text::ignoreCaseArticles($b->{$sortField}) } @$items;
			};
		}

		$cb->( {
			items => $items
		} );
	}, $type, 0);
}

#Sven 2022-05-17 look at 'Info multi AP-Calls.pm'
sub QobuzManageFavorites {
	my ($client, $cb, $params, $args) = @_;
	
	my $status = { artist => -1, album => -1, track => -1};
	my $call = {};
	
	my $callback = sub {
		my $result = shift;
		
		if ($result) {
			$status->{$result->{type}} = $result->{status};
			delete($call->{$result->{type}});
		}
		
		return if (scalar keys %$call > 0);
		
		my $items = [];
		
		if ($status->{artist} > -1) {
			push @$items, {
				name => cstring($client, $status->{artist} ? 'PLUGIN_QOBUZ_REMOVE_FAVORITE' : 'PLUGIN_QOBUZ_ADD_FAVORITE', cstring($client, 'ARTIST') . " '" . $args->{artist} . "'"),
				#name => cstring($client, 'ARTIST') . ':' . $args->{artist},
				#line2 => cstring($client, $status->{artist} ? 'PLUGIN_QOBUZ_REMOVE_FAVORITE' : 'PLUGIN_QOBUZ_ADD_FAVORITE', $args->{artist}),
				image => 'html/images/favorites.png', #$status->{artist} ? 'html/images/favorites_remove.png' : 'html/images/favorites.png',
				type => 'link',
				url  => \&QobuzSetFavorite,
				passthrough => [{ artist_ids => $args->{artistId}, add => !$status->{artist} }],
				nextWindow => 'grandparent'
			};
		}
		
		if ($status->{album} > -1) {
			my $albumname = cstring($client, 'ALBUM') . " '" . $args->{album} . ($args->{artist} ? ' ' . cstring($client, 'BY') . ' ' . $args->{artist} : '') . "'";
			push @$items, {
				name => cstring($client, $status->{album} ? 'PLUGIN_QOBUZ_REMOVE_FAVORITE' : 'PLUGIN_QOBUZ_ADD_FAVORITE', $albumname),
				#name => $args->{album},
				#line2 => cstring($client, $status->{album} ? 'PLUGIN_QOBUZ_REMOVE_FAVORITE' : 'PLUGIN_QOBUZ_ADD_FAVORITE', $args->{album}),
				image => 'html/images/favorites.png', #$status->{album} ? 'html/images/favorites_remove.png' : 'html/images/favorites.png',
				type => 'link',
				url  => \&QobuzSetFavorite,
				passthrough => [{ album_ids => $args->{albumId}, add => !$status->{album} }],
				nextWindow => 'grandparent'
			};
			Plugins::Qobuz::Addon::favMenu($client, $args, $items);
		};
		
		if ($status->{track} > -1) {
			push @$items, {
				name => cstring($client, $status->{track} ? 'PLUGIN_QOBUZ_REMOVE_FAVORITE' : 'PLUGIN_QOBUZ_ADD_FAVORITE', cstring($client, 'TRACK') . " '" . $args->{title} . "'"),
				#name => $args->{title},
				#line2 => cstring($client, $status->{track} ? 'PLUGIN_QOBUZ_REMOVE_FAVORITE' : 'PLUGIN_QOBUZ_ADD_FAVORITE', $args->{title}),
				image => 'html/images/favorites.png', # $status->{track} ? 'html/images/favorites_remove.png' : 'html/images/favorites.png',
				type => 'link',
				url  => \&QobuzSetFavorite,
				passthrough => [{ track_ids => $args->{trackId}, add => !$status->{track} }],
				nextWindow => 'grandparent'
			};
		}
		
		$cb->( { items => $items } );
	};
	
	my $api = getAPIHandler($client);
	
	if ($args->{artist} && $args->{artistId}) {
		$call->{artist} = 1;
		$api->getFavoriteStatus($callback, { item_id => $args->{artistId}, type => 'artist' });
	}
	
	if ($args->{album}  && $args->{albumId}) {
		$call->{album} = 1;
		$api->getFavoriteStatus($callback, { item_id => $args->{albumId}, type => 'album' });
	}
	
	if ($args->{title}  && $args->{trackId}) {
		$call->{track} = 1;
		$api->getFavoriteStatus($callback, { item_id => $args->{trackId},  type => 'track' });
	}
}

#Sven 2022-05-13
sub QobuzSetFavorite {
	my ($client, $cb, $params, $args) = @_;

	getAPIHandler($client)->setFavorite(sub { $cb->(); }, $args);
}

#Sven 2022-05-23
sub QobuzUserPlaylists {
	my ($client, $cb, $params, $args) = @_;

	getAPIHandler($client)->getUserPlaylists(sub {
		_playlistCallback(shift, $cb, 'showOwner', $params->{isWeb}, 'sort');
	}, $args); #Sven 2022-05-23
}

#Sven 2025-09-17 v30.6.2
sub QobuzPlaylistTags {
	my ($client, $cb, $params, $args) = @_;

	my $genreId = $args->{genreId};
	my $type    = $args->{type} || 'editor-picks';
	my $api     = getAPIHandler($client);

	$api->getTags(sub {
		my $tags = shift;

		if ($tags && ref $tags) {
			my $lang = lc(preferences('server')->get('language'));

			my @items = map {
				{
					name => $_->{name}->{$lang} || $_->{name}->{en},
					image => 'html/images/playlists.png',
					type  => 'playlists', #Sven
					url   => \&QobuzPublicPlaylists,
					passthrough => [{
						genreId => $genreId, 
						tags => $_->{id},
						type => $type
					}]
				};
			} @$tags;

			unshift @items, {
				name  => cstring($client, 'PLUGIN_QOBUZ_ALL_PLAYLISTS'),
				image => 'html/images/playlists.png',
				type  => 'playlists',
				url   => \&QobuzPublicPlaylists,
				passthrough => [{
					genreId => $genreId, 
					tags => 'all',
					type => $type
				}]
			};

			unshift @items, {
				name  => cstring($client, 'PLUGIN_QOBUZ_GENRE_SELECT'),
				image => 'html/images/genres.png',
				type  => 'menu', #Sven - view type
				url  => \&QobuzGenreSelection,
				passthrough => [{ filter => 'genreFilter' }],
			} unless ($genreId);

			$cb->( {
				items => \@items
			} );
		}
		else {
			$cb->();
		} 
	});
}

#Sven 2025-09-17 v30.6.2
sub QobuzPublicPlaylists {
	my ($client, $cb, $params, $args) = @_;

	my $genreId = $args->{genreId};
	my $tags    = $args->{tags} || '';
	my $type    = $args->{type} || 'editor-picks';
	my $api     = getAPIHandler($client);

	unless ($genreId) { $genreId = _getGenres(); };
	
	$api->getPublicPlaylists(sub {
		_playlistCallback(shift, $cb, 'showOwner', $params->{isWeb});
	}, $type, $genreId, ($tags eq 'all') ? '' : $tags);
}

#Sven 2022-05-23
sub _playlistCallback {
	my ($searchResult, $cb, $showOwner, $isWeb, $cmd) = @_;

	$searchResult = ($searchResult->{playlists}) ? $searchResult->{playlists} : $searchResult->{similarPlaylist}; #Sven 2022-05-23

	my $playlists = [];

	for my $playlist ( @{$searchResult->{items}} ) {
		next if defined $playlist->{tracks_count} && !$playlist->{tracks_count};
		push @$playlists, _playlistItem($playlist, $showOwner, $isWeb);
	}

	if ($cmd eq 'sort') {
		my $sortPlaylists = $prefs->get('sortPlaylists') || 0;
		if ( $sortPlaylists ) {
			@$playlists = sort { Slim::Utils::Text::ignoreCaseArticles($a->{name}) cmp Slim::Utils::Text::ignoreCaseArticles($b->{name}) } @$playlists;
		};
	}

	$cb->( {
		items => $playlists
	} );
}

#Sven 2022-05-23
sub QobuzSimilarPlaylists {
	my ($client, $cb, $params, $playlistId) = @_;
	
	getAPIHandler($client)->getSimilarPlaylists(sub {
		_playlistCallback(shift, $cb, 'showOwner', $params->{isWeb});
	}, $playlistId);
}

#Sven 2022-05-11 called from _playlistItem
sub QobuzPlaylistItem {
	my ($client, $cb, $params, $playlist, $args) = @_;

	my $items = []; #ref array

	push @$items, {
		name  => $args->{name},
		name2 => $args->{owner},
		image => $args->{image},
		url   => \&QobuzPlaylistGetTracks,
		passthrough => [ $playlist->{id} ],
		type  => 'playlist',
		favorites_url  => 'qobuz://playlist:' . $playlist->{id} . '.qbz', #fügt dem Contextmenu"In Favoriten speichern" hinzu
		favorites_type => 'playlist',
	};

	push @$items, {
		name => $playlist->{tracks_count} . ' ' . cstring($client, ($playlist->{tracks_count} eq 1 ? 'PLUGIN_QOBUZ_TRACK' : 'PLUGIN_QOBUZ_TRACKS')) . ' - ' . cstring($client, 'LENGTH') . ' ' . _sec2hms($playlist->{duration}),
		type  => 'text',
	};

	my $temp = $playlist->{genres};
	if ($temp && ref $temp && scalar @$temp) {
		my $genre_s = '';
		map { $genre_s .= ', ' . $_->{name} } @$temp;
		push @$items, { name  => substr($genre_s, 2), label => 'GENRE', type => 'text' };
	}

	my $temp = $playlist->{featured_artists}; # is a ref of an array
	if ($temp && ref $temp && scalar @$temp) {
		my @artists = map { _artistItem($client, $_, 'withIcon') } @$temp;
		push @$items, { name => cstring($client, 'ARTISTS'), items => \@artists } if scalar @artists; #Ausgewählte Künstler
	}

	if ($playlist->{description}) {
		push @$items, {
			name  => cstring($client, 'DESCRIPTION'),
			items => [{ name => _stripHTML($playlist->{description}), type => 'textarea'}],
		};
	}

	#Sven 2022-05-23 created_at ist vom Datum her immer gleich public_at, die Uhrzeit in public_at ist immer 00:00:00.
	push @$items, {
		name => cstring($client, 'PLUGIN_QOBUZ_RELEASED_AT') . cstring($client, 'COLON') . ' ' . Slim::Utils::DateTime::shortDateF($playlist->{created_at}),
		type  => 'text'
		} if $playlist->{created_at};

	push @$items, {
		name => cstring($client, 'PLUGIN_QOBUZ_UPDATED_AT') . cstring($client, 'COLON') . ' ' . Slim::Utils::DateTime::shortDateF($playlist->{updated_at}),
		type  => 'text'
		} if $playlist->{updated_at};

	push @$items, {
		name => cstring($client, 'PLUGIN_QOBUZ_SIMILAR_PLAYLISTS'),
		type => 'playlists', #'link',
		url  => \&QobuzSimilarPlaylists,
		passthrough => [{ playlist_id => $playlist->{id} }],
		} if $playlist->{stores};

	if ($playlist->{owner}->{id} eq getAPIHandler($client)->userId) { #Sven
		push @$items, {
			name => cstring($client, 'PLUGIN_QOBUZ_REMOVE_PLAYLIST'),
			items => [{
				name => $args->{name} . ' - ' . cstring($client, 'PLUGIN_QOBUZ_REMOVE_PLAYLIST'),
				type => 'link',
				url  => \&QobuzPlaylistCommand,
				passthrough => [{ playlist_id => $playlist->{id}, command => 'delete' }],
				nextWindow => 'grandparent'
			}],	
		};
	}
	else {
		push @$items, {
			name => cstring($client, 'PLUGIN_QOBUZ_SUBSCRIPTION'),
			type => 'link',
			url  => \&QobuzPlaylistSubscription,
			passthrough => [ $playlist ],
		};
	}
	$cb->({ items => $items });
}

#Sven 2022-05-14
sub QobuzPlaylistSubscription {
	my ($client, $cb, $params, $playlist) = @_;
	
	getAPIHandler($client)->getUserPlaylists(sub {
		my $playlists = shift;
		my $isSubscribed;
		
		if ($playlists && ref $playlists && $playlists->{playlists} && ref $playlists->{playlists}) {
			my $playlistId = $playlist->{id};
			foreach (@{$playlists->{playlists}->{items}}) {
				if ($isSubscribed = ($_->{id} eq $playlistId)) { last };
			};
		};
		
		my $item = {
			name => $playlist->{name} . ' - ' . cstring($client, $isSubscribed ? 'PLUGIN_QOBUZ_UNSUBSCRIBE' : 'PLUGIN_QOBUZ_SUBSCRIBE'),
			#line2 => cstring($client, $subscribed ? 'PLUGIN_QOBUZ_UNSUBSCRIBE' : 'PLUGIN_QOBUZ_SUBSCRIBE'), #cstring($client, 'ALBUM')),
			image => 'html/images/favorites.png', #$isFavorite ? 'html/images/favorites_remove.png' : 'html/images/favorites_add.png',
			type => 'link',
			url  => \&QobuzPlaylistCommand,
			passthrough => [{ playlist_id => $playlist->{id}, command => ($isSubscribed ? 'unsubscribe' : 'subscribe') }],
			nextWindow => 'grandparent' #'parent' ist zu wenig, 'grandparent' spring zurück auf die Liste
		};
		
		$cb->( { items => [$item] } );
	});
}

#Sven 2022-05-14
sub QobuzPlaylistCommand {
	my ($client, $cb, $params, $args) = @_;
	
	getAPIHandler($client)->doPlaylistCommand(sub { $cb->() }, $args);
}

#Sven 2019-03-19
#Slim::Utils::DateTime::timeFormat(),
sub _sec2hms {
	my $seconds = @_[0] || '0';

	my $minutes   = int($seconds / 60);
	my $hours     = int($minutes / 60);
	return $hours eq 0 ? sprintf('%02s:%02s', $minutes, $seconds % 60) : sprintf('%s:%02s:%02s', $hours, $minutes % 60, $seconds % 60); 
}

#Sven 2019-04-11, 2022-05-10
sub _quality {
	my $meta = @_[0];
	
	$meta = $meta->{tracks}->{items}[0] if $meta->{tracks}; #Sven 2020-12-31 liest die Qualität aus dem 1. Track wenn $meta ein Album und kein Track ist
	
	my $channels = $meta->{maximum_channel_count};
	if ($channels) {
		if ($channels eq 2) { $channels = '' } # 'Stereo'
		elsif ($channels eq 1) { $channels = ' - Mono' }
		else { $channels = ' - ' . $channels . ' Kanal' }
		
		return $meta->{maximum_bit_depth} . '-Bit ' . $meta->{maximum_sampling_rate} . 'kHz' . $channels;
	}
	return $meta->{bitrate};
}

#Sven 2022-05-05 shows album infos before playing music, it is an enhanced version 'sub QobuzGetTracks {'
sub QobuzGetTracks {
	my ($client, $cb, $params, $args) = @_;
	my $albumId = $args->{album_id};

	my $api = getAPIHandler($client);

	$api->getAlbum(sub {
		my $album = shift;
		my $items = [];

		if (!$album) {  # the album does not exist in the Qobuz library
			$log->warn("Get album ($albumId) failed");
			$api->getUserFavorites(sub {
				my $favorites = shift;
				my $isFavorite = ($favorites && $favorites->{albums}) ? grep { $_->{id} eq $albumId } @{$favorites->{albums}->{items}} : 0;

				push @$items, {
					name  => cstring($client, 'PLUGIN_QOBUZ_ALBUM_NOT_FOUND'),
					type  => 'text'
				};

				if ($isFavorite) {  # if it's an orphaned favorite, let the user delete it
					push @$items, {
						name => cstring($client, 'PLUGIN_QOBUZ_REMOVE_FAVORITE', $args->{album_title}),
						url  => \&QobuzSetFavorite,
						image => 'html/images/favorites.png',
						passthrough => [{
							album_ids => $albumId
						}],
						nextWindow => 'parent'
					};
				}

				$cb->({
					items => $items,
				}, @_ );
			}, 'albums', 0); #Sven 2023-10-09
			return;

		} elsif (!$album->{streamable} && !$prefs->get('playSamples')) {  # the album is not streamable
			push @$items, {
				name  => cstring($client, 'PLUGIN_QOBUZ_NOT_AVAILABLE'),
				type  => 'text'
			};

			$cb->({
				items => $items,
			}, @_ );
			return;
		}

		my $artistname = $album->{artist}->{name} || '';
		my $albumname  = ($artistname && $album->{title} ? $artistname . ' - ' . $album->{title} : $artistname) || '';
		my $conductorname;
		my $albumcredits = $albumname . "\n\n";

		my $totalDuration = 0;
		my $trackNumber = 0;
		my $tracks = [];
		my $works = {};
		my $lastwork = "";
		my $worksfound = 0;
		my $noComposer = 0;
		my $workHeadingPos = 0;
		my $workPlaylistPos = $prefs->get('workPlaylistPosition');
		my $currentComposer = "";
		my $lastComposer = "";
		my $worksWorkId = "";
		my $worksWorkIdE = "";
		my $lastWorksWorkId = "";
		my $discontigWorks;
		my $workComposer;
		my $lastDisc;
		my $discs = {};
		my $performers = {};

		foreach my $track (@{$album->{tracks}->{items}}) {
			_addPerformers($client, $track, $performers);
			$totalDuration += $track->{duration};
			$albumcredits  .= _trackCredits($client, $track) . "\n\n";
			$conductorname  = _getConductor($track) unless ($conductorname);
			my $formattedTrack = _trackItem($client, $track);
			my $work = delete $formattedTrack->{work};

			# create a playlist for each "disc" in a multi-disc set except if we've got works (mixing disc & work playlists would go horribly wrong or at least be confusing!)
			if ( $prefs->get('showDiscs') && $formattedTrack->{media_count} > 1 && !$work ) {
				my $discId = delete $formattedTrack->{media_number};
				$discs->{$discId} = {
					index => $trackNumber,
					title => string('DISC') . " " . $discId,
					image => $formattedTrack->{image},
					tracks => []
				} unless $discs->{$discId};

				push @{$discs->{$discId}->{tracks}}, $formattedTrack;
			}

			if ( $work ) {
				# Qobuz sometimes would f... up work names, randomly putting whitespace etc. in names - ignore them
				my $workId = Slim::Utils::Text::matchCase(Slim::Utils::Text::ignorePunct($work));
				$workId =~ s/\s//g;
				my $displayWorkId = Slim::Utils::Text::matchCase(Slim::Utils::Text::ignorePunct($formattedTrack->{displayWork}));
				$displayWorkId =~ s/\s//g;

				# Unique work identifier, used to keep tracks together even if composer is missing from some, but on the other hand
				# still distinguishing between works with the same name but different composer!
				$currentComposer = $track->{composer}->{name};
				if ( $workId eq $lastwork && (!$lastComposer || !$currentComposer || $lastComposer eq $currentComposer) ) {
					# Stick with the previous value! ($worksWorkId = $worksWorkId;)
				} elsif ( $currentComposer ) {
					$worksWorkId = $displayWorkId;
				} else {
					$worksWorkId = $workId;
				}

				# Extended Work ID: will usually not change, but we need to keep non-contiguous tracks from the same work
				# separate if the user has chosen to integrate playlists with the work titles.
				$worksWorkIdE = $worksWorkId;
				if ( $workPlaylistPos eq "integrated" && $works->{$worksWorkId} ) {
					if ( $worksWorkId ne $lastWorksWorkId ) {
						$discontigWorks->{$worksWorkId} = $worksWorkId . $trackNumber;
					}
					if ( $discontigWorks->{$worksWorkId} ) {
						$worksWorkIdE = $discontigWorks->{$worksWorkId};
					}
				}

				if ( !$works->{$worksWorkIdE} ) {
					$works->{$worksWorkIdE} = {   # create a new work object
						index => $trackNumber,		# index of first track in the work
						title => $formattedTrack->{displayWork},
						tracks => []
					} ;
				}

				# Create new work heading, except when the user has chosen integrated playlists - in that case
				# the work-playlist headings will be spliced in later.
				if ( ( $workId ne $lastwork ) || ( $lastComposer && $currentComposer && $lastComposer ne $currentComposer ) ) {
					$workHeadingPos = push @$tracks,{
						name  => $formattedTrack->{displayWork},
						#type  => 'text' #Sven 2023-10-08 auskommentiert damit das Werk nicht hochgestellt angezeigt wird.
					} unless $workPlaylistPos eq "integrated";

					$noComposer = !$track->{composer}->{name};
					$lastwork = $workId;
				} else {
					$worksfound = 1;   # we found two consecutive tracks with the same work
				}

				push @{$works->{$worksWorkIdE}->{tracks}}, $formattedTrack if $works->{$worksWorkIdE};


				if ($noComposer && $track->{composer}->{name} && $workHeadingPos) {  #add composer to work title if needed
					# Can't update @$items here when using integrated playlists, as there is no work heading in @$items at present.
					if ( $workPlaylistPos ne "integrated" ) {
						@$tracks[$workHeadingPos-1]->{name} = $formattedTrack->{displayWork};
					}
					$works->{$worksWorkIdE}->{title} = $formattedTrack->{displayWork};
					$noComposer = 0;
				}

				# If we're using integrated playlists, save the work title to a temporary structure (including composer if possible -
				# i.e. when there's a composer in at least one of the tracks in the work group).
				if ( $workPlaylistPos eq "integrated" && (!$workComposer->{$worksWorkIdE}->{displayWork} || $track->{composer}->{name}) ) {
					$workComposer->{$worksWorkIdE}->{displayWork} = $formattedTrack->{displayWork};
				}

				$lastComposer = $track->{composer}->{name};

			} elsif ($lastwork ne "") {  # create a separator line for tracks without a work
				push @$tracks,{
					name  => "————————",
					type  => 'text'
				};
				$lastwork = "";
				$noComposer = 0;
			}

			$trackNumber++;
			$lastWorksWorkId = $worksWorkId;

			push @$tracks, $formattedTrack;
		}

		# create a playlist for each "disc" in a multi-disc set except if we've got works (mixing disc & work playlists would go horribly wrong or at least be confusing!)
		if ( $prefs->get('showDiscs') && scalar keys %$discs && !(scalar keys %$works) && _isReleased($album) ) {
			foreach my $disc (sort { $discs->{$b}->{index} <=> $discs->{$a}->{index} } keys %$discs) {
				my $discTracks = $discs->{$disc}->{tracks};

				# insert disc item before the first of its tracks
				splice @$tracks, $discs->{$disc}->{index}, 0, {
					name => $discs->{$disc}->{title},
					image => 'html/images/albums.png', #image => $discs->{$disc}->{image},
					type => 'playlist',
					playall => 1,
					url => \&QobuzWorkGetTracks,
					passthrough => [{
						tracks => $discTracks
					}],
					items => $discTracks
				} if scalar @$discTracks > 1;
			}
		}

		if (scalar keys %$works && _isReleased($album) ) { # don't create work playlists for unreleased albums
			# create work playlists unless there is only one work containing all tracks
			my @workPlaylists = ();
			if ( $worksfound || $workPlaylistPos eq "integrated" ) {   # only proceed if a work with more than 1 contiguous track was found
				my $workNumber = 0;
				foreach my $work (sort { $works->{$a}->{index} <=> $works->{$b}->{index} } keys %$works) {
					my $workTracks = $works->{$work}->{tracks};
					if ( scalar @$workTracks && ( scalar @$workTracks < $album->{tracks_count} || $workPlaylistPos eq "integrated" ) ) {
						if ( $workPlaylistPos eq "integrated" ) {
							# Add playlist as work heading (or just add as text if only one track in the work)
							my $idx = $works->{$work}->{index} + $workNumber;
							my $workTrackCount = @$workTracks;
							if ( $workTrackCount == 1 || $workTrackCount == $album->{tracks_count} ) {
								if ( $worksfound ) {
									splice @$tracks, $idx, 0, {
										name => $workComposer->{$work}->{displayWork},
										image => 'html/images/playlists.png',
									};
								} else {
									splice @$tracks, $idx, 0, {
										name => $workComposer->{$work}->{displayWork},
										type => 'text',
									}
								}
							} else {
								splice @$tracks, $idx, 0, {
									name => $workComposer->{$work}->{displayWork},
									image => 'html/images/playall.png',
									type => 'playlist',
									playall => 1,
									url => \&QobuzWorkGetTracks,
									passthrough => [{
										tracks => $workTracks
									}],
									items => $workTracks
								};
							}
							$workNumber++;
						} else {
							push @workPlaylists, {
								name => $works->{$work}->{title},
								image => 'html/images/playall.png',
								type => 'playlist',
								playall => 1,
								url => \&QobuzWorkGetTracks,
								passthrough => [{
									tracks => $workTracks
								}],
								items => $workTracks
							}
						}
					}
				}
			}
			if ( @workPlaylists ) {
				# insert work playlists according to the user preference
				if ( $workPlaylistPos eq "before" ) {
					unshift @$tracks, @workPlaylists;
				} elsif ( $workPlaylistPos eq "after" ) {
					push @$tracks, @workPlaylists;
				}
			}
		}

		#Page starts here

		#The playlist must not be at the beginning, otherwise the add/play buttons are displayed at the top, but they have no function here.
		#Therefore the genre is displayed first in the first line.
		#Since 2022 that's not true any more, playlist can be the first element.

		#Playlist
		push @$items, {
#			name  => ($album->{version} ? $album->{title} . ' - ' . $album->{version} : $album->{title}),
			name  => sprintf('%s %s %s', ($album->{version} ? $album->{title} . ' - ' . $album->{version} : $album->{title}), cstring($client, 'BY'), $album->{artist}->{name}),
#			line1 => $album->{title} || '',
			line2 => $album->{tracks_count} . ' ' . cstring($client, ($album->{tracks_count} eq 1 ? 'PLUGIN_QOBUZ_TRACK' : 'PLUGIN_QOBUZ_TRACKS')) . ' - ' .
					 _sec2hms($totalDuration) . ' - (' . _quality($album) . ')',
			image => ref $album->{image} ? $album->{image}->{large} : $album->{image},
			type  => 'playlist',
			items => $tracks,
			favorites_url  => 'qobuz:album:' . $album->{id}, #war ein funktionierender Fix für Material-Skin, dort fehlte bis 2.9.5 der Menüpunkt "In Favoriten speichern" im Contextmenu
			favorites_type => 'playlist', #Standardwert ist 'playlist', sonst 'audio' (für Radios oder Tracks)
		};

		if (!_isReleased($album) ) {
			my $rDate = _localDate($album->{release_date_stream});
			push @$items, {
				name  => cstring($client, 'PLUGIN_QOBUZ_NOT_RELEASED') . ' (' . $rDate . ')',
				type  => 'text'
			};
		}

		push @$items, { name => $album->{genre}, label => 'GENRE', type  => 'text' };

		my $item = {};
		my $artist_ref = {}; #Referenz auf anonymen Hash

		if ($conductorname) {
			$artist_ref = lc($conductorname) eq lc($artistname) ? { name => $artistname, id => $album->{artist}->{id} } : { name => $conductorname };
			$item = _artistItem($client, $artist_ref);
			$item->{label} = 'CONDUCTOR';
			push @$items, $item;
		}

		if (!$artist_ref->{id} and ($artist_ref = $album->{artist})) { #only if artist != conductor
			if ($artist_ref->{id} != 145383) { # no Various Artists
				$item = _artistItem($client, $artist_ref);
				$item->{label} = 'ARTIST';
				push @$items, $item;
			}
		}

		if ($item = $album->{composer}) {
			if ($item->{id} != 573076 and $item->{id} != $artist_ref->{id}) { #no Various Composers && artist != composer
				$item = _artistItem($client, $item);
				$item->{label} = 'COMPOSER';
				push @$items, $item;
			}
		}

		#Sven 2022-05-05
		my $temp = $album->{artists}; # is a ref of an array
		if ($temp && ref $temp && scalar @$temp > 1) {
			my @artists = map { _artistItem($client, $_, 'withIcon') } @$temp;
			push @$items, { name => cstring($client, 'ARTISTS'), items => \@artists } if scalar @artists;
		}

		if ($album->{description}) {
			push @$items, {
				name  => cstring($client, 'DESCRIPTION'),
				items => [{ name => _stripHTML($album->{description}), type => 'textarea' }],
			};
		}

		#Sven 2022-05-24 - Stand heute Januar 24 scheint Focus von Qobuz nicht mehr unterstützt zu werden, items_focus ist immer undef;
		my $focusItems = $album->{items_focus};
		if ($focusItems && ref $focusItems && scalar @$focusItems) {
			my @fItems = map { {
				name => $_->{title},
				image => $_->{image},
				items => [{ name => $_->{accroche}, type => 'textarea' }],
				#url => \&QobuzFocus,
				#passthrough => [ { focus_id => $_->{id} }],
				}
			} @$focusItems;
			push @$items, { name  => cstring($client, 'PLUGIN_QOBUZ_FOCUS'), items => \@fItems } if scalar @fItems;
		}

		#Sven 2022-05-01
		my $awards = $album->{awards};
		if ($awards && ref $awards && scalar @$awards) {
			my @awItems = map { {name => Slim::Utils::DateTime::shortDateF($_->{awarded_at}) . ' - ' . $_->{name}, type => 'text' } } @$awards;
			push @$items, { name  => cstring($client, 'PLUGIN_QOBUZ_AWARDS'), items => \@awItems } if scalar @awItems;
		}

		push @$items, { name => cstring($client, 'PLUGIN_QOBUZ_CREDITS'), items => [{ name => $albumcredits, type => 'textarea' }] };

		if ($album->{label} && $album->{label}->{name}) {
			push @$items, {
				name  => cstring($client, 'PLUGIN_QOBUZ_LABEL') . cstring($client, 'COLON') . ' ' . $album->{label}->{name},
				url   => \&QobuzLabel,
				passthrough => [ { labelId => $album->{label}->{id} } ],
				};
		}

		push @$items, { name => cstring($client, 'PLUGIN_QOBUZ_RELEASED_AT') . cstring($client, 'COLON') . ' ' . Slim::Utils::DateTime::shortDateF($album->{released_at}), type  => 'text' } if $album->{released_at};

		#Sven 2020-03-30
		push @$items, { name => 'Copyright', items => [{ name => _stripHTML($album->{copyright}), type => 'textarea' }] } if $album->{copyright};

		if ($IsMusicArtistInfo) {
			push @$items, {
				name => cstring($client, 'PLUGIN_MUSICARTISTINFO_ALBUMINFO'),
				type => 'menu',
				#use AlbumInfo::getAlbumMenu() and not AlbumInfo->getAlbumMenu() to pass $client as first parameter. 
				items => Plugins::MusicArtistInfo::AlbumInfo::getAlbumMenu($client, undef, { album => { album => $album->{title}, artist => $artistname } })
			};	
		}

		# Add a consolidated list of all artists on the album
		$items = _albumPerformers($client, $performers, $album->{tracks_count}, $items);
		
		$item = trackInfoMenuBooklet($client, undef, undef, $album);
		push @$items, $item if $item;

		#Sven 2020-03-30
		push @$items, {
			name => cstring($client, 'PLUGIN_QOBUZ_MANAGE_FAVORITES'),
			type => 'menu', #'link',
			url  => \&QobuzManageFavorites,
			passthrough => [{refalbum => $album, album => $albumname, albumId => $albumId, artist => $artistname, artistId => $album->{artist}->{id}}]
			#url  => \&QobuzToggleFavorites,
			#passthrough => [{ item_id => $albumId, type => 'album', itemname => $albumname }]
		};

		$cb->({
			items => $items
		}, @_ ); #calls callback function with 1 parameters

	}, { album_id => $albumId, extra => 'focus' } );
}

sub _addPerformers {
	my ($client, $track, $performers) = @_;

	if (my $trackPerformers = trackInfoMenuPerformers($client, undef, undef, $track)) {
		my $performerItems = $trackPerformers->{items};
		my $mediaNumber = $track->{'media_number'}||1;
		foreach my $item (@$performerItems) {
			$item->{'track'} = $track->{'track_number'};
			$item->{'disc'}  = $mediaNumber;
		}
		push @{$performers->{$mediaNumber}}, @$performerItems;
	}
}

sub _albumPerformers {
	my ($client, $performers, $trackCount, $items) = @_;

	my @uniquePerformers;
	my %seen = ();
	my $tracks;

	foreach my $disc (sort(keys %$performers)) {
		my %discAdded = ();
		foreach my $item (@{$performers->{$disc}}) {
			push @{$tracks->{$item->{'name'}}->{'tracks'}}, " " . cstring($client, 'DISC') . " $disc" . cstring($client, 'COLON') . " " unless $discAdded{$item->{'name'}}++ || scalar keys %$performers == 1;
			push @{$tracks->{$item->{'name'}}->{'tracks'}}, $item->{'track'};
			delete $item->{'track'};
			push(@uniquePerformers, $item) unless $seen{$item->{'name'}}++;
		}
	}

	if ( scalar @uniquePerformers ) {
		foreach my $item (@uniquePerformers) {
			my @tracks = @{$tracks->{$item->{'name'}}->{'tracks'}};
			my $creditCount = scalar @tracks - (scalar keys %$performers == 1 ? 0 : scalar keys %$performers);
			if ( @tracks && scalar $creditCount < $trackCount ) {
				$item->{'name'} .= " ( ";

				# collapse the track list so that, eg, 1,2,3,5,7,8,9,11,12 becomes 1-3, 5, 7-9, 11-12 and add punctuation to make multi-disc albums somewhat intelligible
				# there's probably a much more perly way of doing this...
				my $sep = "-";
				my $o;
				for my $i ( 0 .. $#tracks ) {
					my $currentValue = $tracks[$i];
					my $currentIsNumber = looks_like_number($currentValue);
					my $nextValue = $tracks[$i+1];
					my $nextIsNumber = looks_like_number($nextValue);
					if ( $currentIsNumber && $nextIsNumber && $nextValue == $currentValue+1 ) {
						$o .= "$currentValue$sep" if $sep;
						$sep = undef;
					} else {
						$o .= "$currentValue";
						$sep = "-";
						if ( $currentIsNumber && $nextIsNumber ) {
							$o .= ", ";
						} elsif ( $currentIsNumber && $nextValue && !$nextIsNumber ) {
							$o .= "; ";
						}
					}
				}

				$item->{'name'} .= "$o )";
			}
		}

		my $item = {
			name => cstring($client, 'PLUGIN_QOBUZ_PERFORMERS'),
			items => \@uniquePerformers,
			type => 'actions',
		};
		push @$items, $item;
	}

	return $items;
}

#Sven 2022-05-10 returns a single string with track credits
sub _trackCredits {
	my ($client, $track) = @_;
	my $details;

	if ($track->{track_number}) {
		$details = sprintf("%02s. %s\n\n", $track->{track_number}, $track->{title});
	}
	else { #called from trackInfoMenuPerformer
	  if ($track->{album}) {
      $details = ' - ' . ((ref $track->{album}) ? $track->{album}->{title} : $track->{album});
	  };
		$details = $track->{title} . $details . "\n\n";
	}

	if ($track->{composer}) {
		my $composer = (ref $track->{composer}) ? $track->{composer}->{name} : $track->{composer};
		$details .= ' . ' . cstring($client, 'COMPOSER') . ': ' . $composer . "\n" if $composer;
	}

	$details .= sprintf(" . %s : %s - (%s)\n\n%s\n", cstring($client, 'LENGTH'), _sec2hms($track->{duration}), _quality($track), cstring($client, 'PLUGIN_QOBUZ_CREDITS'));

	map { s/,/: /; $details .= ' . ' . $_ . "\n"; } split(/ - /, $track->{performers});

	return $details;
}

sub _getConductor {
	my $track = shift;
	
    my $temp = $track->{performers};
	my $pos = index($temp, 'Conductor');
	
	if ($pos >= 0) {
		my $name = substr($temp, 0, $pos - 2);
		$pos = rindex($name, ' - ');
		$name = substr($name, $pos+3) if $pos >= 0;
		return $name;
	}
	return "";
}

sub QobuzWorkGetTracks {
	my ($client, $cb, $params, $args) = @_;
	my $tracks = $args->{tracks};

	$cb->({
		type => 'playlist',
		playall => 1,
		items => $tracks
	});
}

#Sven 2023-10-07
sub QobuzPlaylistGetTracks {
	my ($client, $cb, $params, $playlistId) = @_;

	getAPIHandler($client)->getPlaylistTracks(sub {
		my $playlist = shift;

		if (!$playlist) {
			$log->error("Get playlist ($playlistId) failed");
			$cb->();
			return;
		}

		my $tracks = [];

		foreach my $track (@{$playlist->{tracks}->{items}}) {
			push @$tracks, _trackItem($client, $track, $params->{isWeb});
		}
		$cb->({
			items => $tracks,
		}, @_ );
	}, $playlistId);
}

#Sven 2020-04-01
sub _albumItem {
	my ($client, $album) = @_;

	my $artist = $album->{artist}->{name} || '';
	my $albumname = $album->{title} || '';
	my $albumYear = $prefs->get('showYearWithAlbum') ? $album->{year} || (localtime($album->{released_at}))[5] + 1900 || 0 : 0;

	if ( $album->{hires_streamable} && $albumname !~ /hi.?res|bits|khz/i && $prefs->get('labelHiResAlbums') && Plugins::Qobuz::API::Common->getStreamingFormat($album) eq 'flac' ) {
		$albumname .= ' ' . cstring($client, 'PLUGIN_QOBUZ_HIRES');
	}

	my $item = { image => ref $album->{image} ? $album->{image}->{large} : $album->{image} };

	my $sortFavsAlphabetically = $prefs->get('sortFavsAlphabetically') || 0;
	if ($sortFavsAlphabetically == 1) {
		$item->{name} = $albumname . ($artist ? ' - ' . $artist : '');
	}
	else {
		$item->{name} = $artist . ($artist && $albumname ? ' - ' : '') . $albumname;
	}

	if ($albumname) {
		$item->{line1} = $albumname;
		#$item->{line2} = $artist . " (" . $album->{tracks_count}. ' - ' . (ref $album->{genre} ? $album->{genre}->{name} : $album->{genre}) . ($albumYear ? ' - ' . $albumYear . ')' : ')'); #Sven 2023-10-09 track_count, genre and year added
		$item->{line2} = ( join(', ', map { $_->{name} } Plugins::Qobuz::API::Common->getMainArtists($album)) || $artist )
						. " (" . $album->{tracks_count}. ' - ' . (ref $album->{genre} ? $album->{genre}->{name} : $album->{genre}) . ($albumYear ? ' - ' . $albumYear . ')' : ')'); #Sven 2023-10-09 track_count, genre and year added
#						. ($albumYear ? ' (' . $albumYear . ')' : '');
		$item->{name} .= $albumYear ? "\n(" . $albumYear . ')' : '';
	}

	if ( $prefs->get('parentalWarning') && $album->{parental_warning} ) {
		$item->{name} .= ' [E]';
		$item->{line1} .= ' [E]';
	}

	if ( $album->{released_at} > time  || (!$album->{streamable} && !$prefs->get('playSamples')) ) {
		my $sorry = ' (' . cstring($client, 'PLUGIN_QOBUZ_NOT_AVAILABLE') . ')';
		$item->{name}  .= $sorry;
		$item->{line2} .= $sorry;
		delete $item->{type};
		$item->{type} = 'text';
		delete $item->{url};
	}
	else {
		if (!$album->{streamable} || !_isReleased($album) ) {
			$item->{name}  = '* ' . $item->{name};
			$item->{line2} = '* ' . $item->{line2};
		}
		#Sven 2019-03-17 call the new album info menu	
		$item->{type}        = 'link';
		$item->{url}         = \&QobuzGetTracks;
		$item->{passthrough} = [{ album_id => $album->{id}, album_title => $album->{title} }];
		#$item->{isContextMenu} = 1;
		#$item->{items} = [{ name => 'Test Entry 1', type => 'text' }, { name => 'Test Entry 2', type => 'text' }];
	}

	return $item;
}

#Sven 2019-04-17 returns also artist item if artistid is unknown only with artist name
sub _artistItem {
	my ($client, $artist, $withIcon) = @_;
	my $artistId = $artist->{id};

	if (!$artistId) {
		getAPIHandler($client)->search(sub {
			my $searchResult = shift;
			
			$artistId = @{$searchResult->{artists}->{items} || []}[0] if $searchResult;
			$artistId = $artistId->{id} if $artistId;
			
		}, $artist->{name}, 'artists', { limit => 1 });
	}
	#Sven 2022-05-11 - Erweiterung um Anzeige von Rollen, falls vorhanden
	my $temp = '';
	my $roles = $artist->{roles};
	if ($roles && scalar @$roles) { $temp = ' (' . join(', ', map { $_ } @$roles) . ')'}
	
	my $item =  {
		name => $artist->{name} . $temp,
		type => 'mixed', #'link',
		url  => \&QobuzArtist,
		passthrough => [{ artistId => $artistId }],
		favorites_url  => 'qobuz://artist:' . $artistId, #fügt dem Contextmenu"In Favoriten speichern" hinzu
		favorites_type => 'artist',
	};

	$item->{image} = $artist->{picture} || getAPIHandler($client)->getArtistPicture($artistId) || 'html/images/artists.png' if $withIcon;

	return $item;
}

#Sven 2020-03-28, 2022-05-11
sub _playlistItem {
	my ($playlist, $showOwner, $isWeb) = @_;

	my $image = Plugins::Qobuz::API::Common->getPlaylistImage($playlist);

	my $owner = $showOwner ? $playlist->{owner}->{name} : undef;

	my $name = $playlist->{name} . ($isWeb && $owner ? " - $owner" : '');

	return {
		name  => $name,
		line2 => $owner,
		url   => \&QobuzPlaylistItem,
		image => $image,
		type  => 'link',
		passthrough => [ $playlist, { name => $name, owner => $owner, image => $image } ],
	};
}

#Sven 2023-10-08, 2025-09-22
sub _trackItem {
	my ($client, $track, $isWeb) = @_;

	my $title  = Plugins::Qobuz::API::Common->addVersionToTitle($track);
	if ($track->{track_number}) { $title = sprintf('%02s. %s', $track->{track_number}, $title); } #
	my $album  = $track->{album};
	#my $artist = Plugins::Qobuz::API::Common->getArtistName($track, $album);
	my $artistNames = [ map { $_->{name} } Plugins::Qobuz::API::Common->getMainArtists($album) ];
	Plugins::Qobuz::API::Common->removeArtistsIfNotOnTrack($track, $artistNames);
	if ($track->{performer} && Plugins::Qobuz::API::Common->trackPerformerIsMainArtist($track) ) {
		push @$artistNames, $track->{performer}->{name};
	}
	my %seen;
	my $artist = join(', ', grep { !$seen{$_}++ } @$artistNames);
	my $albumtitle  = $album->{title} || '';
	if ( $albumtitle && $prefs->get('showDiscs') ) {
		$albumtitle = Slim::Music::Info::addDiscNumberToAlbumTitle($albumtitle,$track->{media_number},$album->{media_count});
	}
#	my $genre  = $album->{genre}; #unused

	my $item = {
		#name  => $isWeb ? sprintf('%s - %s', $title, $albumtitle) : sprintf('%02s - %s', $track->{track_number}, $title),
		#line1 => sprintf('%02s. %s', $track->{track_number}, $track->{title}), 
		#line2 => sprintf('%s - %s - %s', _sec2hms($track->{duration}), $artist, _quality($track)),
		#line2 => _sec2hms($track->{duration}) . ' - ' . $artist . ($artist && $albumtitle ? ' - ' : '') . $albumtitle,
		name  => sprintf('%s %s %s %s %s', $title, cstring($client, 'BY'), $artist, cstring($client, 'FROM'), $albumtitle),
		line1 => $title,
		line2 => $artist . ($artist && $albumtitle ? ' - ' : '') . $albumtitle . ' - ' . _sec2hms($track->{duration}), 
		image => Plugins::Qobuz::API::Common->getImageFromImagesHash($album->{image}),
	};

	if ( $track->{hires_streamable} && $item->{name} !~ /hi.?res|bits|khz/i && $prefs->get('labelHiResAlbums') && Plugins::Qobuz::API::Common->getStreamingFormat($album) eq 'flac' ) {
		$item->{name}  .= ' ' . cstring($client, 'PLUGIN_QOBUZ_HIRES');
		$item->{line1} .= ' ' . cstring($client, 'PLUGIN_QOBUZ_HIRES');
	}

	# Enhancements to work/composer display for classical music (tags returned from Qobuz are all over the place)
	if ( $album->{isClassique} ) {
		if ( $track->{work} ) {
			$item->{work} = $track->{work};
		} else {
			# Try to set work to the title, but without composer if it's in there
			if ( $track->{composer}->{name} && $track->{title} ) {
				my @titleSplit = split /:\s*/, $track->{title};
				$item->{work} = $track->{title};
				if ( index($track->{composer}->{name}, $titleSplit[0]) != -1 ) {
					$item->{work} =~ s/\Q$titleSplit[0]\E:\s*//;
				}
			}
			# try to remove the title (ie track, movement) from the work
			my @titleSplit = split /:\s*/, $track->{title};
			my $tempTitle = @titleSplit[-1];
			$item->{work} =~ s/:\s*\Q$tempTitle\E//;
			$item->{line1} =~ s/\Q$item->{work}\E://;
		}
		$item->{displayWork} = $item->{work};
		if ( $track->{composer}->{name} ) {
			$item->{displayWork} = $track->{composer}->{name} . string('COLON') . ' ' . $item->{work};
			my $composerSurname = (split ' ', $track->{composer}->{name})[-1];
			$item->{line1} =~ s/\Q$composerSurname\E://;
		}
		$item->{line2} .= " - " . $item->{work} if $item->{work};
	}

	if ( $album ) {
		$item->{year} = $album->{year} || substr($album->{release_date_stream},0,4) || 0;
	}

	if ( $prefs->get('parentalWarning') && $track->{parental_warning} ) {
		$item->{name} .= ' [E]';
		$item->{line1} .= ' [E]';
	}

	if ($album && $album->{released_at} && $album->{released_at} > time) {
	#if ($track->{released_at} && $track->{released_at} > time) {
		$item->{items} = [{
			name => cstring($client, 'PLUGIN_QOBUZ_NOT_RELEASED'),
			type => 'textarea'
		}];
	}
	elsif (!$track->{streamable} && (!$prefs->get('playSamples') || !$track->{sampleable})) {
		$item->{items} = [{
			name => cstring($client, 'PLUGIN_QOBUZ_NOT_AVAILABLE'),
			type => 'textarea'
		}];
		$item->{name}  = '* ' . $item->{name};
		$item->{line1} = '* ' . $item->{line1};
	}
	else {
		$item->{name}      = $item->{name} . ' *' if ! $track->{streamable};
		$item->{line1}     = '* ' . $item->{line1} if !$track->{streamable};
		#$item->{line2}     = $item->{line2} . ' *' if !$track->{streamable};
		$item->{play}      = Plugins::Qobuz::API::Common->getUrl($client, $track);
		$item->{on_select} = 'play';
		$item->{playall}   = 1;
	}

	#$item->{url} = $item->{play} if $item->{play}; #Wurde am 26.10.2024 von Michael Herger hinzugefügt, wegen Material-Skin? Diese Änderung hatte mein Track-Menü verschwinden lassen.
	if ($item->{play}) { #Sven 2025-09-22 jetzt wird das Track-Menü erst erzeugt und angezeigt, wenn auf den Track geklickt wird und der Menüpunkt 'Mehr...' gewählt wird.
		$item->{url} = \&QobuzTrackMenu;
		$item->{passthrough} = [{ album => $album, title => $item->{name}, artist => $artist, track => $track }];
	};
	$item->{tracknum}     = $track->{track_number};
	$item->{media_number} = $track->{media_number};
	$item->{media_count}  = $album->{media_count};
	return $item;
}

#Sven 2025-09-22
sub QobuzTrackMenu {
	my ($client, $cb, $params, $args) = @_;
	
	my $album = $args->{album};
	my $track = $args->{track};

	my $items = [];

	push @$items, _albumItem($client, $album);

	push @$items, {
		name => cstring($client, 'PLUGIN_QOBUZ_CREDITS'),
		items => [{name => _trackCredits($client, $track), type => 'textarea'}],
	};

	# Add a consolidated list of all artists on the album
	my $performers = {};
	_addPerformers($client, $track, $performers);
	$items = _albumPerformers($client, $performers, 1, $items);

	push @$items, {
		name => cstring($client, 'PLUGIN_QOBUZ_MANAGE_FAVORITES'),
		url  => \&QobuzManageFavorites,
		passthrough => [{
			trackId => $track->{id}, title => $args->{title},
			albumId => $album->{id}, album => $album->{title},
			artist => $args->{artist},
		}],
	};

	$cb->( { items => $items } );
}

#Sven the context menu of a track, creates the 'On Qobuz' menu item in the more menu
sub trackInfoMenu {
	my ( $client, $url, $track, $remoteMeta, $tags ) = @_;

	my $artist = $track->remote ? $remoteMeta->{artist} : $track->artistName;
	my $album  = $track->remote ? $remoteMeta->{album}  : ( $track->album ? $track->album->name : undef );
	my $title  = $track->remote ? $remoteMeta->{title}  : $track->title;
	my $label  = $track->remote ? $remoteMeta->{label} : undef;
	my $labelId = $track->remote ? $remoteMeta->{labelId} : undef;
	my $composer  = $track->remote ? [$remoteMeta->{composer}] : undef;
	my $work = $composer && $remoteMeta->{work} ? ["$remoteMeta->{composer} $remoteMeta->{work}"] : undef;
	
	$artist = (split /,/, $artist)[0]; #Sven 2022-05-03 somtimes a list of artists are received

	my $items = [];

	my ($trackId) = Plugins::Qobuz::ProtocolHandler->crackUrl($url); #Sven 2025-09-27 fix $trackId is defined only with Qobuz url
	if ( defined $trackId) {
		my $albumId = $remoteMeta ? $remoteMeta->{albumId} : undef;
		my $artistId= $remoteMeta ? $remoteMeta->{artistId} : undef;

		if ($trackId || $albumId || $artistId) {
			my $args = {};
			if ($artistId && $artist) {
				$args->{artistId} = $artistId;
				$args->{artist}   = $artist;
			}

			if ($trackId && $title) {
				$args->{trackId} = $trackId;
				$args->{title}   = $title;
			}

			if ($albumId && $album) {
				$args->{albumId} = $albumId;
				$args->{album}   = $album;
			}

			push @$items, {
				name => cstring($client, 'PLUGIN_QOBUZ_MANAGE_FAVORITES'),
				url  => \&QobuzManageFavorites,
				passthrough => [$args],
			} if keys %$args
		}

		if (my $item = trackInfoMenuCredits($client, undef, undef, $remoteMeta)) {
			push @$items, $item;
		}

		# Add a consolidated list of all artists on the track
		my $performers = {};
		_addPerformers($client, $remoteMeta, $performers);
		$items = _albumPerformers($client, $performers, 1, $items);

		if (my $item = trackInfoMenuBooklet($client, undef, undef, $remoteMeta)) {
			push @$items, $item
		}
	}

	return _objInfoHandler( $client, $artist, $album, $title, $items, $label, $labelId, $composer, $work );
}

sub artistInfoMenu {
	my ($client, $url, $artist, $remoteMeta, $tags, $filter) = @_;

	return _objInfoHandler( $client, $artist->name );
}

sub albumInfoMenu {
	my ($client, $url, $album, $remoteMeta, $tags, $filter) = @_;

	my $albumTitle = $album->title;
	my @artists;
	push @artists, $album->artistsForRoles('ARTIST'), $album->artistsForRoles('ALBUMARTIST');

	my $label;
	my $labelId;
	my $composers;
	my $works;
	my $items = [];

	if ( !%$remoteMeta && $url =~ /^qobuz:/ ) {
		my $albumId = (split /:/, $url)[-1];

		my $qobuzAlbum = $cache->get('album_with_tracks_' . $albumId);
		getAPIHandler($client)->getAlbum(sub {
			$qobuzAlbum = shift;

			if (!$qobuzAlbum) {
				$log->error("Get album ($albumId) failed");
				return;
			}
			elsif ( $qobuzAlbum->{release_date_stream} && $qobuzAlbum->{release_date_stream} lt Slim::Utils::DateTime::shortDateF(time, "%Y-%m-%d") ) {
				$cache->set('album_with_tracks_' . $albumId, $qobuzAlbum, QOBUZ_DEFAULT_EXPIRY);
			}
		}, $albumId) unless $qobuzAlbum && ref $qobuzAlbum;

		if ( $qobuzAlbum && ref $qobuzAlbum ) {
			my %seen;
			my $performers = {};
			my $albumcredits;
			foreach my $track (@{$qobuzAlbum->{tracks}->{items}}) {
				_addPerformers($client, $track, $performers);
				$albumcredits .= _trackCredits($client, $track) . "\n\n";
				my $composer = $track->{'composer'}->{'name'};
				my $work = $track->{'work'};
				if ( $track->{'album'}->{'label'} && !$seen{$track->{'label'}} ) {
					$seen{$track->{'album'}->{'label'}} = 1;
					$label = $track->{'album'}->{'label'};
					$labelId = $track->{'album'}->{'labelId'};
				}
				if ( $composer && !$seen{$composer} ) {
					$seen{$composer} = 1;
					push @$composers, $composer;
				}
				if ( $composer && $work && !$seen{"$work $composer"} ) {
					$seen{"$work $composer"} = 1;
					push @$works, "$composer $work";
				}
			}

			my $args = {};
			$args->{albumId} = $qobuzAlbum->{id};
			$args->{album} = $qobuzAlbum->{title};
			$args->{artistId} = $qobuzAlbum->{artist}->{id};
			$args->{artist} = $qobuzAlbum->{artist}->{name};
			push @$items, {
				name => cstring($client, 'PLUGIN_QOBUZ_MANAGE_FAVORITES'),
				url  => \&QobuzManageFavorites,
				passthrough => [$args],
			} if keys %$args;

			if ($albumcredits) {
				$albumcredits = $qobuzAlbum->{title} . "\n\n" . $albumcredits;
				push @$items, { name => cstring($client, 'PLUGIN_QOBUZ_CREDITS'), items => [{ name => $albumcredits, type => 'textarea' }] };
			}

			$items = _albumPerformers($client, $performers, $qobuzAlbum->{tracks_count}, $items);

			if ($qobuzAlbum->{description}) {
				push @$items, {
					name  => cstring($client, 'DESCRIPTION'),
					items => [{
						name => _stripHTML($qobuzAlbum->{description}),
						type => 'textarea',
					}],
				};
			};

			if (my $item = trackInfoMenuBooklet($client, undef, undef, $qobuzAlbum)) {
				push @$items, $item
			}
		}
	}

	return _objInfoHandler( $client, $artists[0]->name, $albumTitle, undef, $items, $label, $labelId, $composers, $works);
}

sub _objInfoHandler {
	my ( $client, $artist, $album, $track, $items, $label, $labelId, $composer, $work ) = @_;

	#Sven 2025-09.28 fix for context menu of a radio playlist item, no 'on Qobuz' if album or artist is not present.
	$track = undef unless ($artist || $album); 

	$items ||= [];

	push @$items, {
		name  => cstring($client, 'PLUGIN_QOBUZ_LABEL') . cstring($client, 'COLON') . ' ' . $label,
		url   => \&QobuzLabel,
		passthrough => [{
			labelId  => $labelId,
		}],
	} if $label && $labelId;

	#Sven 2025-09-28 QobuzSearch with type (albums, artists, tracks, ...), optimized code which is independent from unknown names.
	my $sItems = [ 
		{ type => 'artists', value => $artist, caption => 'ARTIST' },
		{ type => 'albums',  value => $album,  caption => 'ALBUM' },
		{ type => 'tracks',  value => $track,  caption => 'TRACK' },
	];
	push @$sItems, { type => 'artists',  value => $_,  caption => 'COMPOSER' } foreach @$composer;
	push @$sItems, { type => 'works',    value => $_,  caption => 'PLUGIN_QOBUZ_WORK' } foreach @$work;

	foreach (@$sItems) {
		push @$items, {
			name => cstring($client, 'PLUGIN_QOBUZ_SEARCH', cstring($client, $_->{caption}), $_->{value}),
			url  => \&QobuzSearch,
			passthrough => [{
				q => $_->{value},
				type => $_->{type}, #Sven 2025-09-28
			}]
		} if $_->{value};
	}

	my $menu;
	if ( scalar @$items == 1) {
		$menu = $items->[0];
		$menu->{name} = cstring($client, 'PLUGIN_ON_QOBUZ');
	}
	elsif (scalar @$items) {
		$menu = {
			name  => cstring($client, 'PLUGIN_ON_QOBUZ'),
			items => $items
		};
	}

	return $menu if $menu;
}

#Sven - my version
sub trackInfoMenuCredits {
	my ( $client, $url, $track, $remoteMeta, $tags ) = @_;

	if ( $remoteMeta && $remoteMeta->{performers} ) {
		return { name => cstring($client, 'PLUGIN_QOBUZ_CREDITS'), items => [{name => _trackCredits($client, $remoteMeta), type => 'textarea'}] };
	}
}

my $MAIN_ARTIST_RE = qr/MainArtist|\bPerformer\b|ComposerLyricist/i;
my $ARTIST_RE = qr/Performer|Keyboards|Synthesizer|Vocal|Guitar|Lyricist|Composer|Bass|Drums|Percussion||Violin|Viola|Cello|Trumpet|Conductor|Trombone|Trumpet|Horn|Tuba|Flute|Euphonium|Piano|Orchestra|Clarinet|Didgeridoo|Cymbals|Strings|Harp/i;
my $STUDIO_RE = qr/StudioPersonnel|Other|Producer|Engineer|Prod/i;

sub trackInfoMenuPerformers {
	my ( $client, $url, $track, $remoteMeta, $tags ) = @_;

	#if ( $remoteMeta && (my $performers = $remoteMeta->{performers}) ) {
	if ( $remoteMeta && $remoteMeta->{performers} ) {
		my @performers = map {
			s/,?\s?(MainArtist|AssociatedPerformer|StudioPersonnel|ComposerLyricist)//ig;
			s/,/:/;
			{
				name => $_,
				url  => \&QobuzSearch,
				passthrough => [{
					q => (split /:/, $_)[0],
				}]
			}
		} sort {
			return $a cmp $b if $a =~ $MAIN_ARTIST_RE && $b =~ $MAIN_ARTIST_RE;
			return -1 if $a =~ $MAIN_ARTIST_RE;
			return 1 if $b =~ $MAIN_ARTIST_RE;

			return $a cmp $b if $a =~ $ARTIST_RE && $b =~ $ARTIST_RE;
			return -1 if $a =~ $ARTIST_RE;
			return 1 if $b =~ $ARTIST_RE;

			return $a cmp $b if $a =~ $STUDIO_RE && $b =~ $STUDIO_RE;
			return -1 if $a =~ $STUDIO_RE;
			return 1 if $b =~ $STUDIO_RE;

			return $a cmp $b;
		} split(/ - /, $remoteMeta->{performers});

		return {
			name => cstring($client, 'PLUGIN_QOBUZ_PERFORMERS'),
			items => \@performers,
		};
	}

	return {};
}

sub trackInfoMenuBooklet {
	my ( $client, $url, $track, $remoteMeta, $tags ) = @_;

	my $item;

	eval {
		my $goodies = $remoteMeta->{goodies};
		if ($goodies && ref $goodies && scalar @$goodies) {

			# Browser client (eg Material)
			if ( Slim::Utils::Versions->compareVersions($::VERSION, '8.4.0') >= 0 && _isBrowser($client)
				# or null client (eg Default skin)
				|| !$client->controllerUA )
			{
				if (scalar @$goodies == 1 && lc(@$goodies[0]->{name}) eq "livret num\xe9rique") {
					$item = {
						name => _localizeGoodies($client, @$goodies[0]->{name}),
						weblink => @$goodies[0]->{url},
					};
				} else {
					my $items = [];
					foreach ( @$goodies ) {
						if ($_->{url} =~ $GOODIE_URL_PARSER_RE) {
							push @$items, {
								name => _localizeGoodies($client, $_->{name}),
								weblink => $_->{url},
							};
						}
					}
					if (scalar @$items) {
						$item = {
							name => cstring($client, 'PLUGIN_QOBUZ_GOODIES'),
							items => $items
						};
					}
				}

			# jive clients like iPeng etc. can display web content, but need special handling...
			} elsif ( _canWeblink($client) )  {
				$item = {
					name => cstring($client, 'PLUGIN_QOBUZ_GOODIES'),
					itemActions => {
						items => {
							command  => [ 'qobuz', 'goodies' ],
							fixedParams => {
								goodies => to_json($goodies),
							}
						},
					},
				};
			}
		}
	};

	return $item;
}

sub _localizeGoodies {
	my ($client, $name) = @_;

	if ( my $localizedToken = $localizationTable{$name} ) {
		$name = cstring($client, $localizedToken);
	}

	return $name;
}

sub _getGoodiesCLI {
	my $request = shift;

	my $client = $request->client;

	if ($request->isNotQuery([['qobuz'], ['goodies']])) {
		$request->setStatusBadDispatch();
		return;
	}

	$request->setStatusProcessing();

	my $goodies = [ eval { grep {
		$_->{url} =~ $GOODIE_URL_PARSER_RE;
	} @{from_json($request->getParam('goodies'))} } ] || '[]';

	my $i = 0;

	if (!scalar @$goodies) {
		$request->addResult('window', {
			textArea => cstring($client, 'EMPTY'),
		});
		$i++;
	}
	else {
		foreach (@$goodies) {
			$request->addResultLoop('item_loop', $i, 'text', _localizeGoodies($client, $_->{name}) . ' - ' . $_->{description}); #Sven 2022-05-01 add decription
			$request->addResultLoop('item_loop', $i, 'weblink', $_->{url});
			$i++;
		}
	}

	$request->addResult('count', $i);
	$request->addResult('offset', 0);

	$request->setStatusDone();
}

#Sven
sub searchMenu {
	my ( $client, $tags ) = @_;

	my $searchParam = $tags->{search};

	return {
		name => cstring($client, getDisplayName()),
		items => [{
			#name  => $prefs->get('groupReleases') ? cstring($client, 'PLUGIN_QOBUZ_RELEASES') : cstring($client, 'ALBUMS'),
			name  => cstring($client, 'PLUGIN_QOBUZ_RELEASES'),
			url   => \&QobuzSearch,
			type  => 'albums', #Sven - view type
			image => 'html/images/albums.png',
			passthrough => [{
				q        => $searchParam,
				type     => 'albums',
			}],
		},{
			name  => cstring($client, 'ARTISTS'),
			url   => \&QobuzSearch,
			type  => 'artists', #Sven - view type
			image => 'html/images/artists.png',
			passthrough => [{
				q        => $searchParam,
				type     => 'artists',
			}],
		},{
			name  => cstring($client, 'SONGS'),
			url   => \&QobuzSearch,
			type  => 'playlist', #Sven - view type
			image => 'html/images/playlists.png',
			passthrough => [{
				q        => $searchParam,
				type     => 'tracks',
			}],
		},{
			name  => cstring($client, 'PLAYLISTS'),
			url   => \&QobuzSearch,
			type  => 'playlists', #Sven - view type
			image => 'html/images/playlists.png',
			passthrough => [{
				q        => $searchParam,
				type     => 'playlists',
			}],
		}]
	};
}

#Sven - ab hier ist der Kode bisher identisch mit der Version von Michael Herger
sub cliQobuzPlayAlbum {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotCommand([['qobuz'], ['playalbum', 'addalbum']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $client = $request->client();
	my $albumId = $request->getParam('_p2');

	getAPIHandler($client)->getAlbum(sub {
		my $album = shift;

		if (!$album) {
			$log->error("Get album ($albumId) failed");
			return;
		}

		my $tracks = [];

		foreach my $track (@{$album->{tracks}->{items}}) {
			push @$tracks, Plugins::Qobuz::API::Common->getUrl($client, $track);
		}

		my $action = $request->isCommand([['qobuz'], ['addalbum']]) ? 'addtracks' : 'playtracks';

		$client->execute( ["playlist", $action, "listref", $tracks] );
	}, $albumId);

	$request->setStatusDone();
}

sub _canWeblink {
	my ($client) = @_;
	return $client && $client->controllerUA && ($client->controllerUA =~ $WEBLINK_SUPPORTED_UA_RE || $client->controllerUA =~ $WEBBROWSER_UA_RE);
}

sub _isBrowser {
	my ($client) = @_;
	return ( $client && $client->controllerUA && $client->controllerUA =~ $WEBBROWSER_UA_RE );
}

sub _stripHTML {
	my $html = shift;
	$html =~ s/<(?:[^>'”]*|([‘”]).*?\1)*>//ig;
	return $html;
}

sub _imgProxy { if (CAN_IMAGEPROXY) {
	my ($url, $spec) = @_;

	#main::DEBUGLOG && $log->debug("Artwork for $url, $spec");

	# https://github.com/Qobuz/api-documentation#album-cover-sizes
	my $size = Slim::Web::ImageProxy->getRightSize($spec, {
		50 => 50,
		160 => 160,
		300 => 300,
		600 => 600
	}) || 'max';

	$url =~ s/(\d{13}_)[\dmax]+(\.jpg)/$1$size$2/ if $size;

	#main::DEBUGLOG && $log->debug("Artwork file url is '$url'");

	return $url;
} }

sub _isReleased {  # determine if the referenced album has been released
	my ($album) = @_;
	my $ltime = time;
	# only check date field if the release date is within +/- 14 hours of now
	if ($ltime > ($album->{released_at} + 50400)) {
		return 1;
	} elsif ($ltime < ($album->{released_at} - 50400)) {
		return 0;
	} else {  # check the local date
		my $ldate = Slim::Utils::DateTime::shortDateF($ltime, "%Y-%m-%d");
		return ($ldate ge $album->{release_date_stream});
	}
}

sub _localDate {  # convert input date string in format YYYY-MM-DD to localized short date format
	my $iDate = shift;
	my @dt = split(/-/, $iDate);
	return strftime(preferences('server')->get('shortdateFormat'), 0, 0, 0, $dt[2], $dt[1] - 1, $dt[0] - 1900);
}

# TODO - make search per account
sub addRecentSearch {
	my $search = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++addRecentSearch");

	my $list = $prefs->get('qobuz_recent_search') || [];

	$list = [ grep { $_ ne $search } @$list ];

	push @$list, $search;

	shift(@$list) while scalar @$list > MAX_RECENT;

	$prefs->set( 'qobuz_recent_search', $list );
	main::DEBUGLOG && $log->is_debug && $log->debug("--addRecentSearch");
	return;
}

sub _recentSearchesCLI {
	my $request = shift;
	my $client = $request->client;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_recentSearchesCLI");

	# check this is the correct command.
	if ($request->isNotCommand([['qobuz'], ['recentsearches']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $list = $prefs->get('qobuz_recent_search') || [];
	my $del = $request->getParam('deleteMenu') || $request->getParam('delete') || 0;

	if (!scalar @$list || $del >= scalar @$list) {
		$log->error('Search item to delete is outside the history list!');
		$request->setStatusBadParams();
		return;
	}

	my $items = [];

	if (defined $request->getParam('deleteMenu')) {
		push @$items,
		{
			text => cstring($client, 'DELETE') . cstring($client, 'COLON') . ' "' . ($list->[$del] || '') . '"',
			actions => {
				go => {
					player => 0,
					cmd    => ['qobuz', 'recentsearches' ],
					params => {
						delete => $del
					},
				},
			},
			nextWindow => 'parent',
		},
		{
			text => cstring($client, 'PLUGIN_QOBUZ_CLEAR_SEARCH_HISTORY'),
			actions => {
				go => {
					player => 0,
					cmd    => ['qobuz', 'recentsearches' ],
					params => {
						deleteAll => 1
					},
				}
			},
			nextWindow => 'grandParent',
		};

		$request->addResult('offset', 0);
		$request->addResult('count', scalar @$items);
		$request->addResult('item_loop', $items);
	} elsif ($request->getParam('deleteAll')) {
		$prefs->set( 'qobuz_recent_search', [] );
	} elsif (defined $request->getParam('delete')) {
		splice(@$list, $del, 1);
		$prefs->set( 'qobuz_recent_search', $list );
	}

	$request->setStatusDone;
	main::DEBUGLOG && $log->is_debug && $log->debug("--_recentSearchesCLI");
	return;
}

sub getAPIHandler {
	my ($clientOrId) = @_;

	$clientOrId ||= Plugins::Qobuz::API::Common->getSomeUserId();

	my $api;

	if (ref $clientOrId) {
		$api = $clientOrId->pluginData('api');

		if ( !$api ) {
			my $userdata = Plugins::Qobuz::API::Common->getAccountData($clientOrId);
			# if there's no account assigned to the player, just pick one
			if (!$userdata) {
				my $userId = Plugins::Qobuz::API::Common->getSomeUserId();
				$prefs->client($clientOrId)->set('userId', $userId) if $userId;
			}

			$api = $clientOrId->pluginData( api => Plugins::Qobuz::API->new({
				client => $clientOrId
			}) );
		}
	}
	else {
		$api = Plugins::Qobuz::API->new({
			userId => $clientOrId
		});
	}

	logBacktrace("Failed to get a Qobuz API instance: $clientOrId") unless $api;

	return $api;
}

1;
