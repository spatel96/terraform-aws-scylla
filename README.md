# terraform-aws-scylladb

Terraform module for deploying ScyllaDB cluster on AWS. It also deploys [Scylla Monitoring Stack](https://docs.scylladb.com/operating-scylla/monitoring/monitoring_stack/) alongside the cluster, to monitor its metrics.

### Example with included VPC/subnets

```hcl
module "scylla-cluster" {
	source  = "github.com/spatel96/terraform-aws-scylla"
	aws_instance_type = "t3.large"

	cluster_count = 3
	cluster_user_cidr = ["0.0.0.0/0"]
}
```
### Example without VPC

```hcl
module "scylla-cluster" {
	source  = "github.com/spatel96/terraform-aws-scylla"
	aws_instance_type = "t3.large"

	cluster_count = 3
	cluster_user_cidr = ["0.0.0.0/0"]
	vpc_id            = "<you_vpc_id>"
  	subnet_id         = ["<subnet_a>","<subnet-b>","<subnet-c>"]
}
```
### Usage

Once you configure the module, create the cluster with:

```
$ terraform apply -no-color -auto-approve
```

To destroy the cluster, tear it down with:

```
$ terraform destroy -auto-approve
```

### Related modules

- https://github.com/rjeczalik/terraform-aws-scylla-bench
