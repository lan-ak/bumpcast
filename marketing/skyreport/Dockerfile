# The Sky Report website on Cloud Run. Built from the context deploy_gcp.sh assembles, which
# mirrors the repo's layout: marketing/skyreport/, site/ and ios/Shared/Fonts/.
FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1
WORKDIR /app
COPY site/ site/
COPY ios/Shared/Fonts/ ios/Shared/Fonts/
COPY marketing/skyreport/report.py marketing/skyreport/build_site.py marketing/skyreport/serve.py marketing/skyreport/
RUN useradd --system --no-create-home web
USER web
CMD ["python3", "marketing/skyreport/serve.py"]
