FROM ruby:3.0

RUN bundle config --global frozen 1

WORKDIR /app

COPY Gemfile Gemfile.lock ./

RUN bundle install

COPY . .

# RUN bundle config path 'vendor/bundle'

CMD [ "ruby", "update.rb" ]
