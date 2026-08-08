# --- Etape 1 : construction ---
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /build

# Les dependances sont resolues avant la copie des sources : le cache Docker
# reste valide tant que le pom.xml ne change pas.
COPY pom.xml .
RUN mvn -B -q dependency:go-offline

COPY src ./src
RUN mvn -B -DskipTests package

# --- Etape 2 : execution ---
FROM eclipse-temurin:21-jre-jammy
WORKDIR /app

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --create-home planif

COPY --from=build /build/target/*.jar /app/planif-coeur.jar
RUN chown -R planif:planif /app

USER planif
EXPOSE 8080
ENV TZ=UTC \
    JAVA_OPTS="-XX:MaxRAMPercentage=75"

HEALTHCHECK --interval=30s --timeout=3s --start-period=60s --retries=3 \
    CMD curl -fsS http://localhost:8080/sante || exit 1

ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar /app/planif-coeur.jar"]
