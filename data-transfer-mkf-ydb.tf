# Infrastructure for the Yandex Cloud YDB, Managed Service for Apache Kafka® and Data Transfer.
#
# RU: https://yandex.cloud/ru/docs/data-transfer/tutorials/data-transfer-mkf-ydb
# EN: https://yandex.cloud/en/docs/data-transfer/tutorials/data-transfer-mkf-ydb
#
# Set source cluster and target database settings.
locals {
  folder_id = "" # Your cloud folder ID, same as for the Yandex Cloud provider.

  # Source Managed Service for Apache Kafka® cluster settings:
  source_kf_version    = "" # Set Managed Service for Apache Kafka® cluster version.
  source_user_name     = "" # Set a username in the Managed Service for Apache Kafka® cluster.
  source_user_password = "" # Set a password for the user in the Managed Service for Apache Kafka® cluster.

  # Target Managed Service for YDB cluster settings:
  target_db_name   = "" # Set the Managed Service for YDB database name.
  data_stream_name = "" # Enter the name of the data stream after it's created.

  # Transfer settings:
  transfer_enable = 0 # Set to 1 to enable Transfer.
}

resource "yandex_vpc_network" "network" {
  name        = "network"
  description = "Network for the Managed Service for Apache Kafka® and YDB clusters"
}

# Subnet in ru-central1-a availability zone
resource "yandex_vpc_subnet" "subnet-a" {
  name           = "subnet-a"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = ["10.1.0.0/16"]
}

# Security group for the Managed Service for Apache Kafka® and YDB clusters
resource "yandex_vpc_default_security_group" "security-group" {
  network_id = yandex_vpc_network.network.id

  ingress {
    protocol       = "TCP"
    description    = "Allow connections to the Managed Service for Apache Kafka® cluster from the Internet"
    port           = 9091
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    protocol       = "ANY"
    description    = "Allow outgoing connections to any required resource"
    from_port      = 0
    to_port        = 65535
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# Managed Service for Apache Kafka® cluster
resource "yandex_mdb_kafka_cluster" "kafka-cluster" {
  name               = "kafka-cluster"
  environment        = "PRODUCTION"
  network_id         = yandex_vpc_network.network.id
  security_group_ids = [yandex_vpc_default_security_group.security-group.id]

  config {
    assign_public_ip = true
    brokers_count    = 1
    version          = local.source_kf_version
    zones            = ["ru-central1-a"]
    kafka {
      resources {
        resource_preset_id = "s2.micro"
        disk_type_id       = "network-hdd"
        disk_size          = 10 # GB
      }
    }
  }
}

resource yandex_mdb_kafka_user "kafka-user" {
  cluster_id = yandex_mdb_kafka_cluster.kafka-cluster.id
  name       = local.source_user_name
  password   = local.source_user_password
  depends_on = [
    yandex_mdb_kafka_cluster.kafka-cluster
  ]

  permission {
    topic_name = "sensors"
    role       = "ACCESS_ROLE_CONSUMER"
  }

  permission {
    topic_name = "sensors"
    role       = "ACCESS_ROLE_PRODUCER"
  }
}

resource "yandex_mdb_kafka_topic" "sensors" {
  cluster_id         = yandex_mdb_kafka_cluster.kafka-cluster.id
  name               = "sensors"
  partitions         = 4
  replication_factor = 1
}

# Managed Service for YDB cluster
resource "yandex_ydb_database_serverless" "ydb" {
  name        = local.target_db_name
  location_id = "global"
}

# Service account that Data Transfer will use to connect to the target stream
resource "yandex_iam_service_account" "yds-sa" {
  description = "Service account for the data stream"
  name        = "yds-sa"
}

# Assign the "yds.editor" role to the service account
resource "yandex_resourcemanager_folder_iam_binding" "yds-editor" {
  folder_id = local.folder_id
  role      = "yds.editor"
  members   = [
    "serviceAccount:${yandex_iam_service_account.yds-sa.id}"
  ]
}

# Data Transfer infrastructure

resource "yandex_datatransfer_endpoint" "kf-source" {
  description = "Source endpoint for the Managed Service for Apache Kafka® cluster"
  count       = local.transfer_enable
  name        = "kf-source"
  settings {
    kafka_source {
      connection {
        cluster_id = yandex_mdb_kafka_cluster.kafka-cluster.id
      }
      auth {
        sasl {
          user = yandex_mdb_kafka_user.kafka-user.name
          password {
            raw = local.source_user_password
          }
        }
      }
      topic_names = [
        yandex_mdb_kafka_topic.sensors.name
      ]
      parser {
        json_parser {
          data_schema {
            fields {
              fields {
                name = "device_id"
                type = "STRING"
                key  = true
              }
              fields {
                name = "datetime"
                type = "STRING"
              }
              fields {
                name = "latitude"
                type = "DOUBLE"
              }
              fields {
                name = "longitude"
                type = "DOUBLE"
              }
              fields {
                name = "altitude"
                type = "DOUBLE"
              }
              fields {
                name = "speed"
                type = "DOUBLE"
              }
              fields {
                name = "battery_voltage"
                type = "DOUBLE"
              }
              fields {
                name = "cabin_temperature"
                type = "UINT16"
              }
              fields {
                name = "fuel_level"
                type = "UINT16"
              }
            }
          }
        }
      }
    }
  }
}

resource "yandex_datatransfer_endpoint" "yds-target" {
  description = "Target endpoint for the Managed Service for YDB cluster"
  count       = local.transfer_enable
  name        = "yds-target"
  settings {
    yds_target {
      database           = yandex_ydb_database_serverless.ydb.database_path
      stream             = local.data_stream_name
      service_account_id = yandex_iam_service_account.yds-sa.id
      serializer {
        serializer_auto {
        }
      }
    }
  }
}

resource "yandex_datatransfer_transfer" "mkf-ydb-transfer" {
  count       = local.transfer_enable
  description = "Transfer from the Managed Service for Apache Kafka® to the YDB database"
  name        = "transfer-from-mkf-to-ydb"
  source_id   = yandex_datatransfer_endpoint.kf-source[count.index].id
  target_id   = yandex_datatransfer_endpoint.yds-target[count.index].id
  type        = "INCREMENT_ONLY" # Replication data from the source Data Stream.
}
