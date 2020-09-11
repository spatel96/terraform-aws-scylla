provider "aws" {
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
  region     = var.aws_region
}

locals {
  aws_az = data.aws_availability_zones.all.names
  aws_tags = {
    environment = var.environment
    version     = var.scylla_version
    cluster_id  = random_uuid.cluster_id.result
    keep        = "alive"
  }
  private_key  = tls_private_key.scylla.private_key_pem
  public_key   = tls_private_key.scylla.public_key_openssh
  cluster_name = "cluster-${random_uuid.cluster_id.result}"
  scylla_ami   = var.aws_ami_scylla[format("%s_%s", var.cluster_scylla_version, var.aws_region)]
}

resource "random_uuid" "cluster_id" {
}

resource "tls_private_key" "scylla" {
  algorithm = "RSA"
  rsa_bits  = "2048"
}

resource "aws_instance" "scylla" {
  ami               = local.scylla_ami
  instance_type     = var.aws_instance_type
  key_name          = aws_key_pair.support.key_name
  monitoring        = true
  availability_zone = element(local.aws_az, count.index % length(local.aws_az))
  subnet_id         = element(aws_subnet.subnet.*.id, count.index)
  user_data         = format(join("\n", var.scylla_args), local.cluster_name)

  security_groups = [
    aws_security_group.cluster.id,
    aws_security_group.cluster_admin.id,
    aws_security_group.cluster_user.id,
  ]

  credit_specification {
    cpu_credits = "unlimited"
  }

  tags = merge(
    local.aws_tags,
    {
      "type" = "scylla"
    },
  )
  count = var.cluster_count

  depends_on = [
    aws_security_group.cluster,
    aws_security_group.cluster_admin,
    aws_security_group.cluster_user,
  ]
}

resource "aws_instance" "monitor" {
  ami               = var.aws_ami_monitor[var.aws_region]
  instance_type     = "t3.medium"
  key_name          = aws_key_pair.support.key_name
  monitoring        = true
  availability_zone = element(local.aws_az, 0)
  subnet_id         = element(aws_subnet.subnet.*.id, 0)
  security_groups = [
    aws_security_group.cluster.id,
    aws_security_group.cluster_admin.id,
    aws_security_group.cluster_user.id,
  ]

  credit_specification {
    cpu_credits = "unlimited"
  }

  tags = merge(
    local.aws_tags,
    {
      "type" = "monitor"
    },
  )

  depends_on = [
    aws_security_group.cluster,
    aws_security_group.cluster_admin,
    aws_security_group.cluster_user,
  ]
}

resource "null_resource" "scylla" {
  triggers = {
    cluster_instance_ids = join(",", aws_instance.scylla.*.id)
    elastic_ips          = join(",", aws_eip.scylla.*.public_ip)
  }

  connection {
    type        = "ssh"
    host        = element(aws_eip.scylla.*.public_ip, count.index)
    user        = "centos"
    private_key = local.private_key
    timeout     = "5m"
  }

  provisioner "file" {
    destination = "/tmp/provision-common.sh"
    content     = data.template_file.provision_common_sh.rendered
  }

  provisioner "file" {
    destination = "/tmp/provision-s3.sh"
    content     = data.template_file.provision_s3_sh.rendered
  }

  provisioner "file" {
    destination = "/tmp/provision-scylla.sh"
    content = element(
      data.template_file.provision_scylla_sh.*.rendered,
      count.index,
    )
  }

  provisioner "file" {
    destination = "/tmp/provision-scylla-schema.sh"
    content     = data.template_file.provision_scylla_schema_sh.rendered
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/provision-common.sh",
      "sudo /tmp/provision-common.sh",
      "chmod +x /tmp/provision-s3.sh",
      "sudo /tmp/provision-s3.sh",
      "/tmp/provision-s3.sh",
    ]
  }

  count = var.cluster_count
}

resource "null_resource" "scylla_start" {
  triggers = {
    cluster_instance_ids = join(",", aws_instance.scylla.*.id)
    elastic_ips          = join(",", aws_eip.scylla.*.public_ip)
  }

  connection {
    type        = "ssh"
    host        = element(aws_eip.scylla.*.public_ip, count.index)
    user        = "centos"
    private_key = local.private_key
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/provision-scylla.sh",
      "sudo /tmp/provision-scylla.sh",
      "sudo service scylla-server start",
    ]
  }

  count      = var.cluster_count
  depends_on = [null_resource.scylla]
}

resource "null_resource" "scylla_schema" {
  triggers = {
    id = element(aws_instance.scylla.*.id, 0)
  }

  connection {
    type        = "ssh"
    host        = element(aws_eip.scylla.*.public_ip, 0)
    user        = "centos"
    private_key = local.private_key
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/provision-scylla-schema.sh",
      "sudo /tmp/provision-scylla-schema.sh",
    ]
  }

  depends_on = [null_resource.scylla_start]
}

resource "null_resource" "monitor" {
  triggers = {
    cluster_instance_ids = join(",", aws_instance.scylla.*.id)
    elastic_ips          = join(",", aws_eip.scylla.*.public_ip)
    monitor_id           = aws_instance.monitor.id
  }

  connection {
    type        = "ssh"
    host        = aws_eip.monitor.public_ip
    user        = "centos"
    private_key = local.private_key
    timeout     = "5m"
  }

  provisioner "file" {
    destination = "/tmp/rule_config.yml"
    content     = data.template_file.config_monitor_rule_yml.rendered
  }

  provisioner "file" {
    destination = "/tmp/provision-common.sh"
    content     = data.template_file.provision_common_sh.rendered
  }

  provisioner "file" {
    destination = "/tmp/provision-monitor-common.sh"
    content     = data.template_file.provision_monitor_common_sh.rendered
  }

  provisioner "file" {
    destination = "/tmp/provision-monitor.sh"
    content     = data.template_file.provision_monitor_sh.rendered
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/provision-common.sh",
      "sudo /tmp/provision-common.sh",
      "chmod +x /tmp/provision-monitor-common.sh",
      "sudo /tmp/provision-monitor-common.sh",
      "chmod +x /tmp/provision-monitor.sh",
      "/tmp/provision-monitor.sh",
    ]
  }

  depends_on = [null_resource.scylla_start]
}

resource "aws_key_pair" "support" {
  key_name   = "cluster-support-${random_uuid.cluster_id.result}"
  public_key = local.public_key
}

resource "aws_vpc" "vpc" {
  cidr_block = "10.0.0.0/16"

  tags = local.aws_tags
}

resource "aws_internet_gateway" "vpc_igw" {
  vpc_id = aws_vpc.vpc.id

  tags = local.aws_tags
}

resource "aws_subnet" "subnet" {
  availability_zone       = element(local.aws_az, count.index % length(local.aws_az))
  cidr_block              = format("10.0.%d.0/24", count.index)
  vpc_id                  = aws_vpc.vpc.id
  map_public_ip_on_launch = true

  tags = local.aws_tags

  count      = var.cluster_count
  depends_on = [aws_internet_gateway.vpc_igw]
}

resource "aws_eip" "scylla" {
  vpc      = true
  instance = element(aws_instance.scylla.*.id, count.index)

  tags = merge(
    local.aws_tags,
    {
      "type" = "scylla"
    },
  )

  count      = var.cluster_count
  depends_on = [aws_internet_gateway.vpc_igw]
}

resource "aws_eip" "monitor" {
  vpc      = true
  instance = aws_instance.monitor.id

  tags = merge(
    local.aws_tags,
    {
      "type" = "monitor"
    },
  )

  depends_on = [aws_internet_gateway.vpc_igw]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.vpc_igw.id
  }

  tags = local.aws_tags
}

resource "aws_route_table_association" "public" {
  route_table_id = aws_route_table.public.id
  subnet_id      = element(aws_subnet.subnet.*.id, count.index)

  count = var.cluster_count
}

resource "aws_security_group" "cluster" {
  name        = "cluster-${random_uuid.cluster_id.result}"
  description = "Security Group for inner cluster connections"
  vpc_id      = aws_vpc.vpc.id

  tags = local.aws_tags
}

resource "aws_security_group_rule" "cluster_egress" {
  type              = "egress"
  security_group_id = aws_security_group.cluster.id
  cidr_blocks       = ["0.0.0.0/0"]
  from_port         = "0"
  to_port           = "0"
  protocol          = "-1"
}

resource "aws_security_group_rule" "cluster_ingress" {
  type              = "ingress"
  security_group_id = aws_security_group.cluster.id
  cidr_blocks = concat(
    ["${aws_eip.monitor.public_ip}/32"],
    data.template_file.scylla_cidr.*.rendered
  )
  from_port = element(var.node_ports, count.index)
  to_port   = element(var.node_ports, count.index)
  protocol  = "tcp"

  count = length(var.node_ports)
}

resource "aws_security_group_rule" "cluster_ingress_sg" {
  type                     = "ingress"
  security_group_id        = aws_security_group.cluster.id
  source_security_group_id = aws_security_group.cluster.id
  from_port                = element(var.node_ports, count.index)
  to_port                  = element(var.node_ports, count.index)
  protocol                 = "tcp"

  count = length(var.node_ports)
}

resource "aws_security_group_rule" "cluster_monitor" {
  type              = "ingress"
  security_group_id = aws_security_group.cluster.id
  cidr_blocks = [
    "${aws_eip.monitor.public_ip}/32",
  ]
  from_port = element(var.monitor_ports, count.index)
  to_port   = element(var.monitor_ports, count.index)
  protocol  = "tcp"

  count = length(var.monitor_ports)
}

resource "aws_security_group_rule" "cluster_monitor_sg" {
  type                     = "ingress"
  security_group_id        = aws_security_group.cluster.id
  source_security_group_id = aws_security_group.cluster.id
  from_port                = element(var.monitor_ports, count.index)
  to_port                  = element(var.monitor_ports, count.index)
  protocol                 = "tcp"

  count = length(var.monitor_ports)
}

resource "aws_security_group" "cluster_admin" {
  name        = "cluster-admin-${random_uuid.cluster_id.result}"
  description = "Security Group for the admin of cluster #${random_uuid.cluster_id.result}"
  vpc_id      = aws_vpc.vpc.id

  tags = local.aws_tags
}

resource "aws_security_group_rule" "cluster_admin_egress" {
  type              = "egress"
  security_group_id = aws_security_group.cluster_admin.id
  cidr_blocks       = ["0.0.0.0/0"]
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
}

resource "aws_security_group_rule" "cluster_admin_ingress" {
  type              = "ingress"
  security_group_id = aws_security_group.cluster_admin.id
  cidr_blocks = compact(
    concat(
      [format("%s/32", data.external.ifconfig_co.result.public_ip)],
      var.cluster_admin_cidr,
    ),
  )
  from_port = element(var.admin_ports, count.index)
  to_port   = element(var.admin_ports, count.index)
  protocol  = "tcp"

  count = length(var.admin_ports)
}

resource "aws_security_group" "cluster_user" {
  name        = "cluster-user-${random_uuid.cluster_id.result}"
  description = "Security Group for the user of cluster #${random_uuid.cluster_id.result}"
  vpc_id      = aws_vpc.vpc.id

  tags = local.aws_tags
}

resource "aws_security_group_rule" "cluster_user_egress" {
  type              = "egress"
  security_group_id = aws_security_group.cluster_user.id
  cidr_blocks       = ["0.0.0.0/0"]
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
}

resource "aws_security_group_rule" "cluster_user_ingress" {
  type              = "ingress"
  security_group_id = aws_security_group.cluster_user.id
  cidr_blocks = compact(
    concat(
      [format("%s/32", data.external.ifconfig_co.result.public_ip)],
      var.cluster_user_cidr,
    ),
  )
  from_port = element(var.user_ports, count.index)
  to_port   = element(var.user_ports, count.index)
  protocol  = "tcp"

  count = length(var.user_ports)
}

