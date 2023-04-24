FROM ruby:3.0

WORKDIR /app

RUN bundle config path 'vendor/bundle'

