# ELK Stack + Filebeat

This project contains the configuration for ELK (Elasticsearch, Logstash, Kibana) stack and Filebeat running in a Kubernetes environment.

## Components

- **Elasticsearch**: Search engine that stores and searches log data
- **Logstash**: Data processing pipeline that collects and transforms logs
- **Kibana**: Visualization dashboard for analyzing log data
- **Filebeat**: Lightweight log shipper for collecting and forwarding log files
- **APM Server**: Application Performance Monitoring server for collecting and processing application traces
- **Metricbeat**: Lightweight shipper for system and service metrics

## Architecture

- Log Pipeline:
  - Filebeat(log shipper) -> Logstash(data processor) -> Elasticsearch(storage) <- Kibana(visualization)

<br/>

- Metric Pipeline:
  - Metricbeat(metric collector) -> Elasticsearch(storage) <- Kibana(visualization)

<br/>

- APM Pipeline:
  - Applications(APM agents) -> APM Server -> Elasticsearch(storage) <- Kibana(visualization)

## Installation Guides

- [Elasticsearch Installation](./elasticsearch/README.md)
- [Logstash Installation](./logstash/README.md)
- [Kibana Installation](./kibana/README.md)
- [Filebeat Installation](./filebeat/README.md)
- [APM Server Installation](./apm-server/README.md)
- [Metricbeat Installation](./metricbeat/README.md)

## Reference

- [Elastic Helm Charts](https://github.com/elastic/helm-charts)
- [Elastic APM Documentation](https://www.elastic.co/guide/en/apm/guide/current/index.html)
- [Metricbeat Documentation](https://www.elastic.co/guide/en/beats/metricbeat/current/index.html)