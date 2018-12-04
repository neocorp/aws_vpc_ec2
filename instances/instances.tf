provider "aws" {
  region = "${var.region}"
}

terraform {
  backend "s3" {}
}

data "terraform_remote_state" "network_configuration" {
  backend = "s3"

  config {
    bucket = "${var.remote_state_bucket}"
    key    = "${var.remote_state_key}"
    region = "${var.region}"
  }
}

resource "aws_security_group" "ec2_public_security_group" {
  name        = "EC2-Public-SG"
  description = "Internet reaching access for EC2 Instances"
  vpc_id      = "${data.terraform_remote_state.network_configuration.vpc_id}"

  ingress {
    from_port   = 80
    protocol    = "TCP"
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    protocol    = "TCP"
    to_port     = 22
    cidr_blocks = ["82.222.72.138/32"]
  }

  egress {
    from_port   = 0
    protocol    = "-1"
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ec2_private_security_group" {
  name              = "EC2-Private-SG"
  description       = "Only allow public SG resources to access these instances"
  vpc_id            = "${data.terraform_remote_state.network_configuration.vpc_id}"

  ingress {
    from_port       = 0
    protocol        = "-1"
    to_port         = 0
    security_groups = ["${aws_security_group.ec2_public_security_group.id}"]
  }

  ingress {
    from_port       = 80
    protocol        = "TCP"
    to_port         = 80
    cidr_blocks     = ["0.0.0.0/0"]
    description     = "Allow heatlh checking for instances using this SG"
  }

  egress {
    from_port = 0
    protocol = "-1"
    to_port = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "elb_security_group" {
  name = "ELB-SG"
  description = "ELB Security Group"
  vpc_id = "${data.terraform_remote_state.network_configuration.vpc_id}"

  ingress {
    from_port = 0
    protocol = "-1"
    to_port = 0
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow web traffic to load balancer"
  }

  egress {
    from_port = 0
    protocol = "-1"
    to_port = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "ec2_iam_role" {
  name               = "EC2-IAM-Role"
  assume_role_policy = <<EOF
{
  "Version" : "2012-10-17",
  "Statement" :
  [
    {
      "Effect" : "Allow",
      "Principal" : {
        "Service" : ["ec2.amazonaws.com", "application-autoscaling.amazonaws.com"]
      },
      "Action" : "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "ec2_iam_role_policy" {
  name    = "EC2-IAM-Policy"
  role    = "${aws_iam_role.ec2_iam_role.id}"
  policy  = <<EOF
{
  "Version" : "2012-10-17",
  "Statement" : [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:*",
        "elasticloadbalancing:*",
        "cloudwatch:*",
        "logs:*"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}

resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "EC2-IAM-Instance-Profile"
  role = "${aws_iam_role.ec2_iam_role.name}"
}

data "aws_ami" "launch_configuration_ami" {
  most_recent = true

  filter {
    name    = "owner-alias"
    values  = ["amazon"]
  }
}

resource "aws_launch_configuration" "ec2_private_launch_configuration" {
  image_id                    = "ami-09693313102a30b2c"
  instance_type               = "${var.ec2_instance_type}"
  key_name                    = "${var.key_pair_name}"
  associate_public_ip_address = false
  iam_instance_profile        = "${aws_iam_instance_profile.ec2_instance_profile.name}"
  security_groups             = ["${aws_security_group.ec2_private_security_group.id}"]

  user_data = <<EOF
    #!/bin/bash
    yum update -y
    yum install httpd -y
    service httpd start
    chkconfig httpd on
    export INSTANCE_ID=$(curl http://169.254.169.254/latest/meta-data/instance-id)
    echo "<html><body><h1>Hello from Production Backend at instance <b>"$INSTANCE_ID"</b></h1></body></html>" > /var/www/html/index.html
  EOF
}

resource "aws_launch_configuration" "ec2_public_launch_configuration" {
  image_id                    = "ami-09693313102a30b2c"
  instance_type               = "${var.ec2_instance_type}"
  key_name                    = "${var.key_pair_name}"
  associate_public_ip_address = true
  iam_instance_profile        = "${aws_iam_instance_profile.ec2_instance_profile.name}"
  security_groups             = ["${aws_security_group.ec2_public_security_group.id}"]

  user_data = <<EOF
    #!/bin/bash
    yum update -y
    yum install httpd -y
    service httpd start
    chkconfig httpd on
    export INSTANCE_ID=$(curl http://169.254.169.254/latest/meta-data/instance-id)
    echo "<html><body><h1>Hello from Production Web App at instance <b>"$INSTANCE_ID"</b></h1></body></html>" > /var/www/html/index.html
  EOF
}

resource "aws_elb" "webapp_load_balancer" {
  name            = "Production-WebApp-LoadBalancer"
  internal        = false
  security_groups = ["${aws_security_group.elb_security_group.id}"]
  subnets = [
    "${data.terraform_remote_state.network_configuration.public_subnet_1_id}",
    "${data.terraform_remote_state.network_configuration.public_subnet_2_id}",
    "${data.terraform_remote_state.network_configuration.public_subnet_3_id}"
  ]

  "listener" {
    instance_port = 80
    instance_protocol = "HTTP"
    lb_port = 80
    lb_protocol = "HTTP"
  }

  health_check {
    healthy_threshold   = 5
    interval            = 30
    target              = "HTTP:80/index.html"
    timeout             = 10
    unhealthy_threshold = 5
  }
}

resource "aws_elb" "backend_load_balancer" {
  name            = "Production-Backend-LoadBalancer"
  internal        = true
  security_groups = ["${aws_security_group.elb_security_group.id}"]
  subnets = [
    "${data.terraform_remote_state.network_configuration.private_subnet_1_id}",
    "${data.terraform_remote_state.network_configuration.private_subnet_2_id}",
    "${data.terraform_remote_state.network_configuration.private_subnet_3_id}"
  ]

  "listener" {
    instance_port     = 80
    instance_protocol = "HTTP"
    lb_port           = 80
    lb_protocol       = "HTTP"
  }

  health_check {
    healthy_threshold   = 5
    interval            = 30
    target              = "HTTP:80/index.html"
    timeout             = 10
    unhealthy_threshold = 5
  }
}

resource "aws_autoscaling_group" "ec2_private_autoscaling_group" {
  name                = "Production-Backend-AutoScalingGroup"
  vpc_zone_identifier = [
    "${data.terraform_remote_state.network_configuration.private_subnet_1_id}",
    "${data.terraform_remote_state.network_configuration.private_subnet_2_id}",
    "${data.terraform_remote_state.network_configuration.private_subnet_3_id}"
  ]
  max_size              = "${var.max_instance_size}"
  min_size              = "${var.min_instance_size}"
  launch_configuration  = "${aws_launch_configuration.ec2_private_launch_configuration.name}"
  health_check_type     = "ELB"
  load_balancers        = ["${aws_elb.backend_load_balancer.name}"]

  tag {
    key                 = "Name"
    propagate_at_launch = false
    value               = "Backend-EC2-Instance"
  }

  tag {
    key                 = "Type"
    propagate_at_launch = false
    value               = "Backend"
  }
}

resource "aws_autoscaling_group" "ec2_public_autoscaling_group" {
  name                  = "Production-WebApp-AutoScalingGroup"
  vpc_zone_identifier   = [
    "${data.terraform_remote_state.network_configuration.public_subnet_1_id}",
    "${data.terraform_remote_state.network_configuration.public_subnet_2_id}",
    "${data.terraform_remote_state.network_configuration.public_subnet_3_id}"
  ]
  max_size              = "${var.max_instance_size}"
  min_size              = "${var.min_instance_size}"
  launch_configuration  = "${aws_launch_configuration.ec2_public_launch_configuration.name}"
  health_check_type     = "ELB"
  load_balancers        = ["${aws_elb.webapp_load_balancer.name}"]

  tag {
    key                 = "Name"
    propagate_at_launch = false
    value               = "WebApp-EC2-Instance"
  }

  tag {
    key                 = "Type"
    propagate_at_launch = false
    value               = "WebApp"
  }
}

resource "aws_autoscaling_policy" "webapp_production_scaling_policy" {
  autoscaling_group_name    = "${aws_autoscaling_group.ec2_public_autoscaling_group.name}"
  name                      = "Production-WebApp-AutoScaling-Policy"
  policy_type               = "TargetTrackingScaling"
  min_adjustment_magnitude  = 1

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 80.0
  }
}

resource "aws_autoscaling_policy" "backend_production_scaling_policy" {
  autoscaling_group_name    = "${aws_autoscaling_group.ec2_private_autoscaling_group.name}"
  name                      = "Production-Backend-AutoScaling-Policy"
  policy_type               = "TargetTrackingScaling"
  min_adjustment_magnitude  = 1

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 80.0
  }
}

resource "aws_sns_topic" "webapp_production_autoscaling_alert_topic" {
  display_name = "WebApp-AutoScaling-Topic"
  name         = "WebApp-AutoScaling-Topic"
}

resource "aws_sns_topic_subscription" "webapp_production_autoscaling_sms_subscription" {
  endpoint  = "PHONE_NUMBER"
  protocol  = "sms"
  topic_arn = "${aws_sns_topic.webapp_production_autoscaling_alert_topic.arn}"
}

resource "aws_autoscaling_notification" "webapp_autoscaling_notification" {
  group_names   = ["${aws_autoscaling_group.ec2_public_autoscaling_group.name}"]
  notifications = [
    "autoscaling:EC2_INSTANCE_LAUNCH",
    "autoscaling:EC2_INSTANCE_TERMINATE",
    "autoscaling:EC2_INSTANCE_LAUNCH_ERROR"
  ]
  topic_arn     = "${aws_sns_topic.webapp_production_autoscaling_alert_topic.arn}"
}















