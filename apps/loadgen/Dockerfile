# curl + busybox sh, small image.
FROM curlimages/curl:8.23.0
COPY --chmod=755 loadgen.sh /loadgen.sh
# uid 100 = "curl_user" in the base image; numeric so k8s runAsNonRoot can verify it
USER 100
ENTRYPOINT ["/loadgen.sh"]
