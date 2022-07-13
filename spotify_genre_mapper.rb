require 'net/http'
require 'uri'
require 'json'

MIN_TRACKS_FOR_GENRE = 3
if (!ARGV[0])
  puts 'OAuth token required as an argument. Like this:'
  puts '$ ruby spotify_genre_mapper.rb "MY_OAUTH_TOKEN_HERE"'
  puts 'OAuth token can be found at https://developer.spotify.com/console/get-track/ by clicking "GET TOKEN"'
  return
end
BEARER_TOKEN = ARGV[0]
POST = "POST"
GOOD_RESPONSE_CODES = ["200", "201"]

def json_request (url, request_type = nil, body = nil)
  uri = URI.parse(url)

  request = nil
  if (request_type == POST)
    request = Net::HTTP::Post.new(uri)
  else
    request = Net::HTTP::Get.new(uri)
  end

  request.content_type = "application/json"
  request["Accept"] = "application/json"
  request["Authorization"] = "Bearer #{BEARER_TOKEN}"
  if (body)
    request.body = JSON.dump(body)
  end

  response = Net::HTTP.start(uri.hostname, uri.port, { use_ssl: uri.scheme == "https" }) do |http|
    http.request(request)
  end

  puts_json_bug(response, "#{request_type || ''} #{url}")
  JSON.parse(response.body)
end

def puts_json_bug (response, error_message)
  if !(GOOD_RESPONSE_CODES.include?(response.code))
    puts "----- ERROR #{error_message}"
    puts "----- ERROR CODE #{response.code}"
    if response.body
      puts "----- ERROR BODY #{response.body}"
    end
  end
end

def strip_tracks_response (response)
  # Reformat response data for easier processing
  stripped_tracks = {}
  response["items"].each { |i|
    track = i["track"];
    track_id = track["id"];

    stripped_tracks[track_id] = {
      name: track["name"],
      artists: track["artists"].map { |a| a["id"] },
    }
  }

  stripped_tracks
end

def get_all_spotify_tracks
  my_tracks_response = json_request("https://api.spotify.com/v1/me/tracks?limit=50")
  my_tracks = strip_tracks_response(my_tracks_response)

  while my_tracks_response["next"] do
    my_tracks_response = json_request(my_tracks_response["next"])
    my_tracks = my_tracks.merge(strip_tracks_response(my_tracks_response))
  end

  my_tracks
end

def map_genre_to_tracks (tracks, artist_to_genre_cache)
  genre_to_tracks = {}
  rate_limit_counter = 0

  tracks.keys.each { |track_id|
    track_tuple = [track_id, tracks[track_id][:name]]

    # Tracks don't have genre, only artists. So find all genres for all artists of the track, and add it to a map { genre => [tracks] }
    tracks[track_id][:artists].each { |artist|
      artist_genres = nil

      if artist_to_genre_cache.keys.include?(artist) # Cache hit
        artist_genres = artist_to_genre_cache[artist]
      else
        if rate_limit_counter >= 100
          sleep 31
          rate_limit_counter = 0
        end

        artist_genres = json_request("https://api.spotify.com/v1/artists/#{artist}")["genres"]
        rate_limit_counter += 1
        puts artist_genres

        if artist_genres
          artist_to_genre_cache[artist] = artist_genres
        end
      end

      artist_genres.each { |genre|
        if genre_to_tracks[genre]
          if !genre_to_tracks[genre].include?(track_tuple)
            genre_to_tracks[genre] << track_tuple
          end
        else
          genre_to_tracks[genre] = [track_tuple]
        end
      }
    }
  }

  # Avoid unnecessary processing by removing genres with < X tracks
  genre_to_tracks = genre_to_tracks.filter { |genre| genre_to_tracks[genre].count >= MIN_TRACKS_FOR_GENRE }
  genre_to_tracks
end

def process_genres_to_playlists (genre_to_tracks)
  mutable_genre_to_tracks = genre_to_tracks.clone
  playlists_to_create = {}

  while mutable_genre_to_tracks.keys.count > 0 do
    # Find the genre with the most tracks
    new_genre = mutable_genre_to_tracks.keys.sort { |g1, g2|
      mutable_genre_to_tracks[g2].count <=> mutable_genre_to_tracks[g1].count
    }[0]
    new_genre_tracks = mutable_genre_to_tracks[new_genre]

    mutable_genre_to_tracks.delete(new_genre)
    if new_genre_tracks.count >= MIN_TRACKS_FOR_GENRE
      playlists_to_create[new_genre] = new_genre_tracks

      # If the genre is substantial, remove tracks tagged with that genre from other genres, to avoid duplicates
      mutable_genre_to_tracks.keys.each { |genre|
        mutable_genre_to_tracks[genre] = mutable_genre_to_tracks[genre].filter { |track |
          !new_genre_tracks.include?(track)
        }
      }
    end
  end

  playlists_to_create
end

def find_uncategorized_tracks(my_tracks, playlists_to_create)
  # A track is uncategorized if
  # 1. it was made by artist(s) that Spotify has not assigned genres to
  # 2. process_genres_to_playlists finds that the track belonged only to genres with < MIN_TRACKS_FOR_GENRE tracks
  starting_tracks = []
  my_tracks.keys.each do |track_id|
    starting_tracks << [track_id, my_tracks[track_id][:name]]
  end

  categorized_tracks = []
  playlists_to_create.keys.each do |genre|
    categorized_tracks += playlists_to_create[genre]
  end

  uncategorized_tracks = starting_tracks - categorized_tracks
end

def main
  # API calls
  my_tracks = get_all_spotify_tracks
  artist_to_genre_cache = {} # Cache to avoide doing multiple getArtist API calls
  genre_to_tracks = map_genre_to_tracks(my_tracks, artist_to_genre_cache)

  # Processing tracks into playlists
  playlists_to_create = process_genres_to_playlists(genre_to_tracks)
  uncategorized_tracks = find_uncategorized_tracks(my_tracks, playlists_to_create)
  playlists_to_create["uncategorized"] = uncategorized_tracks
  # 95 / 150 63%, or 4600 / 5100 categorized is about 89%

  # Creating playlists
  USER_ID = "123345762" # This shouldn't be hard coded
  playlists_to_create.keys.each do |genre|
    new_playlist_response = json_request("https://api.spotify.com/v1/users/#{USER_ID}/playlists", POST, {
      "name" => "My #{genre}",
      "description" => "",
      "public" => false
    })

    playlist_id = new_playlist_response["id"]
    num_requests_needed = playlists_to_create[genre].count / 100
    for offset in 0..num_requests_needed do
      request_uris = playlists_to_create[genre][offset * 100 .. offset * 100 + 99].map { |track_tuple|
        "spotify:track:#{track_tuple[0]}"
      }

      add_tracks_response = json_request("https://api.spotify.com/v1/playlists/#{playlist_id}/tracks", POST, { "uris" => request_uris })
    end
  end

  puts playlists_to_create
  # What to do about conflicting artists on a single song? SEEB remix
  # Could sort by descending dancability?
  # Could try reversing - create playlists for microgenres first (3+ songs)... or start with small genres of ... 10+ songs, move up, rather than mega genres and move down
  #   Or the average of the largest genre count and smallest - rather than a set number. Too small ends up with too many playlists, too big loses resolution
  # Is having all of the playlists a bad thing? Too many genres gets overwhelming
  # This could be a parameter at some point - "prefer_general" "prefer_niche"
  # Starting with smaller genres also captures more tracks into playlists, because these genres don't get pushed below the threshold by larger genres - "long tail"
  # MapGenreToTracks should batch artists request so that bearer token does not expire
end

main
