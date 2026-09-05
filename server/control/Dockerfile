FROM dart:3.13.0 AS build

WORKDIR /app
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get
COPY . .
RUN dart compile exe bin/server.dart -o /bin/lanchat-control

FROM dart:3.13.0

COPY --from=build /bin/lanchat-control /usr/local/bin/lanchat-control
COPY web /app/web

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/lanchat-control"]
