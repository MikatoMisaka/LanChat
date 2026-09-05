ARG DART_IMAGE=dart:3.13.0
FROM ${DART_IMAGE} AS build

WORKDIR /app
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get
COPY . .
RUN dart compile exe bin/server.dart -o /bin/lanchat-control

FROM ${DART_IMAGE}

COPY --from=build /bin/lanchat-control /usr/local/bin/lanchat-control
COPY web /app/web

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/lanchat-control"]
