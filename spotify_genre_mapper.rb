require 'net/http'
require 'uri'
require 'json'

MIN_TRACKS_FOR_GENRE = 3
BEARER_TOKEN = ARGV[0] || "BQCBiB6Z5C0lmNNvvbQfy2DLzBUyOnwS966C71_A6iFswmXDYs96lifYGxmkEEW3yBZIwjGzo2sFB7uf2-djexbotJ_yGBn4Eo4pGSk29lSY7dHa__j3CIwxZ7MbEil6UcQuX2PagImBXSJJ6jAxir_RjAib6-bnTJ-ytyblU_mt1DMIwoJUKxcn4UZ-nlsTt3Dx4_JzAiNGcb2UZ_AAj2ErKr9BQ9SLjlVy-w"

def json_request (url)
  uri = URI.parse(url)

  request = Net::HTTP::Get.new(uri)
  request.content_type = "application/json"
  request["Accept"] = "application/json"
  request["Authorization"] = "Bearer #{BEARER_TOKEN}"

  response = Net::HTTP.start(uri.hostname, uri.port, { use_ssl: uri.scheme == "https" }) do |http|
    http.request(request)
  end

  JSON.parse(response.body)
end

def strip_tracks_response (response)
  stripped_tracks = {}
  response["items"].each { |i|
    track = i["track"];
    track_id = track["id"];
    puts track_id;
    my_tracks[track_id] = {
      name: track["name"],
      artists: track["artists"].map { |a| a["id"] },
    }
  }

  stripped_tracks
end

def map_genre_to_tracks (tracks)
  genre_to_tracks = {}
  my_tracks.keys.each { |track_id|
    track_tuple = [track_id, my_tracks[track_id][:name]]

    my_tracks[track_id][:artists].each { |artist|
      artist_genres = nil

      if artist_to_genre.keys.include?(artist) # Cache hit
        artist_genres = artist_to_genre[artist]
      else
        puts "searching artist"
        artist_genres = json_request("https://api.spotify.com/v1/artists/#{artist}")["genres"]
        artist_to_genre[artist] = artist_genres
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
    new_genre = mutable_genre_to_tracks.keys.sort { |g1, g2|
      mutable_genre_to_tracks[g2].count <=> mutable_genre_to_tracks[g1].count
    }[0]
    new_genre_tracks = mutable_genre_to_tracks[new_genre]

    mutable_genre_to_tracks.delete(new_genre)
    if new_genre_tracks.count >= MIN_TRACKS_FOR_GENRE
      playlists_to_create[new_genre] = new_genre_tracks
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

artist_to_genre = {} # Cache to avoide doing multiple getArtist API calls
my_tracks_response = json_request("https://api.spotify.com/v1/me/tracks?limit=50")
my_tracks = strip_tracks_response(my_tracks_response);
genre_to_tracks = map_genre_to_tracks(my_tracks)
playlists_to_create = process_genres_to_playlists(genre_to_tracks)
uncategorized_tracks = find_uncategorized_tracks(my_tracks, playlists_to_create)
playlists_to_create["uncategorized"] = uncategorized_tracks

# What to do about conflicting artists on a single song? SEEB remix
