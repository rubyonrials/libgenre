require 'net/http'
require 'uri'
require 'json'

def json_request (url)
  uri = URI.parse(url)

  request = Net::HTTP::Get.new(uri)
  request.content_type = "application/json"
  request["Accept"] = "application/json"
  request["Authorization"] = "Bearer BQCBiB6Z5C0lmNNvvbQfy2DLzBUyOnwS966C71_A6iFswmXDYs96lifYGxmkEEW3yBZIwjGzo2sFB7uf2-djexbotJ_yGBn4Eo4pGSk29lSY7dHa__j3CIwxZ7MbEil6UcQuX2PagImBXSJJ6jAxir_RjAib6-bnTJ-ytyblU_mt1DMIwoJUKxcn4UZ-nlsTt3Dx4_JzAiNGcb2UZ_AAj2ErKr9BQ9SLjlVy-w"

  response = Net::HTTP.start(uri.hostname, uri.port, { use_ssl: uri.scheme == "https" }) do |http|
    http.request(request)
  end

  JSON.parse(response.body)
end

my_tracks_response = json_request("https://api.spotify.com/v1/me/tracks?limit=50")
my_tracks = {};
my_tracks_response["items"].each { |i|
  track = i["track"];
  track_id = track["id"];
  puts track_id;
  my_tracks[track_id] = {
    name: track["name"],
    artists: track["artists"].map { |a| a["id"] },
  }
}

artist_to_genre = {} # Cache to avoide doing multiple getArtist API calls
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

puts "GENRE_TO_TRACKS WITHOUT FILTER"
puts genre_to_tracks

# Avoid unnecessary processing by removing genres with < 5 tracks
MIN_TRACKS_FOR_GENRE = 3
genre_to_tracks = genre_to_tracks.filter { |genre| genre_to_tracks[genre].count >= MIN_TRACKS_FOR_GENRE }
puts "GENRE_TO_TRACKS WITH FILTER"
puts genre_to_tracks
# Sort them in order of matching tracks
# sorted_big_genres = genre_to_tracks.keys.sort { |g1, g2| genre_to_tracks[g2].count <=> genre_to_tracks[g1].count }

# Go through each genre starting from the biggest.
# 1. Make a new playlist for that genre
# 2. Add all matching tracks to a "blacklist"
# 3. Remove blacklisted tracks from all remaining genre lists
# 4. Re-sort
mutable_genre_to_tracks = genre_to_tracks.clone
playlists_to_create = {}
# mutable_big_genres = sorted_big_genres.clone
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

starting_tracks = []
my_tracks.keys.each do |track_id|
  starting_tracks << [track_id, my_tracks[track_id][:name]]
end

categorized_tracks = []
playlists_to_create.keys.each do |genre|
  categorized_tracks += playlists_to_create[genre]
end

uncategorized_tracks = starting_tracks - categorized_tracks
playlists_to_create["uncategorized"] = uncategorized_tracks

# What to do about conflicting artists on a single song? SEEB remix
