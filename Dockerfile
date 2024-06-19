# Use Maven to build the project
FROM docker-remote.registry.kroger.com/maven:3.6.3-openjdk-8 as build

# Define build arguments and environment variables
ARG CUSTOM_MVN_SETTINGS=https://artifactory.kroger.com/artifactory/kroger-alm/maven/config/settings.xml
ENV MAVEN_OPTS="-Xmx2g -Xss128M -XX:MetaspaceSize=512M -XX:MaxMetaspaceSize=1024M -XX:+CMSClassUnloadingEnabled"
ENV JAVA_OPTS="-XX:+UseG1GC -Xms1g -Xmx2g -XX:+UseParallelGC -XX:+UseStringDeduplication -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/opt/tmp/heapdump.bin"
ENV TZ="America/New_York"

# Copy Maven settings
ADD ${CUSTOM_MVN_SETTINGS} /usr/share/maven/conf/settings.xml

# Copy project files and build
COPY . /
WORKDIR /
RUN mvn clean package

# Use a minimal base image for running the application
FROM docker-remote.artifactory-edge.kroger.com/eclipse-temurin:8u332-b09-jre
ARG JAVA_KEYSTORE_PATH=lib/security/cacerts

# Define build argument
ARG JAR_FILE=./target/*.jar

# Copy the built JAR file from the build stage
COPY --from=build ${JAR_FILE} ./app.jar

# Set environment variables
ENV JAVA_OPTS="-XX:+UseG1GC -Xms1g -Xmx3g -XX:+UseParallelGC -XX:MaxMetaspaceSize=1024M -XX:+UseStringDeduplication -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/opt/tmp/heapdump.bin"
ENV SPRING_PROFILES_ACTIVE="local"


# Copy certificate files and update CA certificates
ADD certs/ /usr/local/share/ca-certificates
RUN update-ca-certificates

# Import certificates into Java keystore in batches
RUN for f in /usr/local/share/ca-certificates/*; do \
  echo "Importing cert into java keystore: $f"; \
  keytool -importcert -keystore "${JAVA_HOME}/${JAVA_KEYSTORE_PATH}" -trustcacerts -storepass changeit -noprompt -file "$f" -v -alias "$f"; \
  done
# Switch back to non-root user
RUN groupadd -g 999 containeruser && \
  useradd -r -u 999 -g containeruser containeruser && \
  mkdir -p /home/containeruser && \
  chown -R containeruser /home/containeruser

USER containeruser
# Expose port
EXPOSE 8080

# Run the application
CMD ["java", "-jar", "/app.jar"]
