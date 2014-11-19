local utils = require 'mp.utils'
local msg = require 'mp.msg'

local ytdl = {
    path = "youtube-dl",
    minver = "2014.11.09",
    vercheck = nil,
}

mp.add_hook("on_load", 10, function ()

    local function exec(args)
        local ret = utils.subprocess({args = args})
        return ret.status, ret.stdout
    end

    local url = mp.get_property("stream-open-filename")

    if (url:find("http://") == 1) or (url:find("https://") == 1)
        or (url:find("ytdl://") == 1) then

       -- check version of youtube-dl if not done yet
        if (ytdl.vercheck == nil) then

             -- check for youtube-dl in mpv's config dir
            local ytdl_mcd = mp.find_config_file("youtube-dl")
            if not (ytdl_mcd == nil) then
                msg.verbose("found youtube-dl at: " .. ytdl_mcd)
                ytdl.path = ytdl_mcd
            end

            msg.debug("checking ytdl version ...")
            local es, version = exec({ytdl.path, "--version"})
            if (es < 0) then
                msg.warn("youtube-dl not found, not executable, or broken.")
                ytdl.vercheck = false
            elseif (version < ytdl.minver) then
                msg.verbose("found youtube-dl version: " .. version)
                msg.warn("Your version of youtube-dl is too old! "
                    .. "You need at least version '"..ytdl.minver
                    .. "', try running `youtube-dl -U`.")
                ytdl.vercheck = false
            else
                msg.verbose("found youtube-dl version: " .. version)
                ytdl.vercheck = true
            end
        end

        if not (ytdl.vercheck) then
            return
        end

        -- strip ytdl://
        if (url:find("ytdl://") == 1) then
            url = url:sub(8)
        end

        -- subformat workaround
        local subformat = "srt"
        if url:find("crunchyroll.com") then
            subformat = "ass"
        end

        local es, json = exec({
            ytdl.path, "-J", "--flat-playlist", "--all-subs",
            "--sub-format", subformat, "--no-playlist", "--", url
            })

        if (es < 0) or (json == nil) or (json == "") then
            msg.warn("youtube-dl failed, trying to play URL directly ...")
            return
        end

        local json, err = utils.parse_json(json)

        if (json == nil) then
            msg.error("failed to parse JSON data: " .. err)
            return
        end

        msg.info("youtube-dl succeeded!")

        -- what did we get?
        if not (json["direct"] == nil) and (json["direct"] == true) then
            -- direct URL, nothing to do
            msg.verbose("Got direct URL")
            return
        elseif not (json["_type"] == nil) and (json["_type"] == "playlist") then
            -- a playlist

            local playlist = "#EXTM3U\n"
            for i, entry in pairs(json.entries) do
                local site = entry.url

                -- some extractors will still return the full info for
                -- all clips in the playlist and the URL will point
                -- directly to the file in that case, which we don't
                -- want so get the webpage URL instead, which is what
                -- we want
                if not (entry["webpage_url"] == nil) then
                    site = entry["webpage_url"]
                end

                playlist = playlist .. "ytdl://" .. site .. "\n"
            end

            mp.set_property("stream-open-filename", "memory://" .. playlist)

        else -- probably a video
            local streamurl = ""

            -- DASH?
            if not (json["requested_formats"] == nil) then
                msg.info("NOTE: Using DASH, expect inaccurate duration.")
                -- video url
                streamurl = json["requested_formats"][1].url

                -- audio url
                mp.set_property("file-local-options/audio-file",
                    json["requested_formats"][2].url)

                -- workaround for slow startup (causes inaccurate duration)
                mp.set_property("file-local-options/demuxer-lavf-o",
                    "fflags=+ignidx")

            elseif not (json.url == nil) then
                -- normal video
                streamurl = json.url
            else
                msg.error("No URL found in JSON data.")
                return
            end

            msg.debug("streamurl: " .. streamurl)

            mp.set_property("stream-open-filename", streamurl)

            mp.set_property("file-local-options/media-title", json.title)

            -- add subtitles
            if not (json.subtitles == nil) then
                for lang, script in pairs(json.subtitles) do
                    msg.verbose("adding subtitle ["..lang.."]")

                    local slang = lang
                    if (lang:len() > 3) then
                        slang = lang:sub(1,2)
                    end

                    mp.commandv("sub_add", "memory://"..script,
                        "auto", lang.." "..subformat, slang)
                end
            end

            -- for rtmp
            if not (json.play_path == nil) then
                mp.set_property("file-local-options/stream-lavf-o",
                    "rtmp_tcurl=\""..streamurl..
                    "\",rtmp_playpath=\""..json.play_path.."\"")
            end
        end
    end
end)
