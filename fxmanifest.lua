fx_version 'cerulean'
game 'rdr3'
rdr3_warning 'I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships.'
lua54 'yes'

name 'uhost-stash-redm-sdk'
author 'uhost.id'
description 'UHost Stash SDK for RedM: screenshot, video & audio uploads to stash.uhost.id'
version '1.0.0'
repository 'https://github.com/UHost-Indonesia/uhost-stash-redm-sdk'

shared_script 'config.lua'
server_script 'server/main.lua'
client_script 'client/main.lua'

-- screenshot-basic is only needed for screenshots (takeImage / takeServerImage)
-- and is checked at call time, so it is not a hard dependency.
