#!/usr/bin/env bash

docker compose run --build --rm app bundle exec ruby update.rb
