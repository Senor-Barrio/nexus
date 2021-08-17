provider "aws" {
  region = "us-east-2"
}

# Getting availability zones for the region specified in region
data "aws_availability_zones" "available" {
  state = "available"
}

# Changing name of Default VPC
resource "aws_default_vpc" "production" {
  tags = {
    Name = "production"
  }
}

#Configuring Default Subnet One
resource "aws_default_subnet" "subnet_1" {
  availability_zone = "us-east-2a"

  tags = {
    Name = "Subnet for us-east-2a"
  }
}

#Configuring Default Subnet Two
resource "aws_default_subnet" "subnet_2" {
  availability_zone = "us-east-2b"

  tags = {
    Name = "Default subnet for us-east-2b"
  }
}

# Creating Role
resource "aws_iam_role" "ec2_s3_access_role" {
  name               = "s3-role"
  assume_role_policy = file("assume_role_policy.json")
}

#Creating IAM Instance Profile
resource "aws_iam_instance_profile" "s3_access_profile" {
  name       = "s3_access_profile"
  role       = aws_iam_role.ec2_s3_access_role.name
  depends_on = [aws_iam_policy.s3-policy]
}

# Creating IAM Policy
resource "aws_iam_policy" "s3-policy" {
  name        = "s3-policy"
  description = "A test policy"
  policy      = file("s3bucketpolicy.json")
}

# Attaching policy to role
resource "aws_iam_policy_attachment" "s3-policy-attachment" {
  name       = "s3-policy-attachment"
  roles      = ["${aws_iam_role.ec2_s3_access_role.name}"]
  policy_arn = aws_iam_policy.s3-policy.arn
}

# Creating autoscaling policy
resource "aws_autoscaling_policy" "nexus-asg-policy-1" {
  name                   = "nexus-asg-policy"
  scaling_adjustment     = 1
  policy_type            = "SimpleScaling"
  adjustment_type        = "ChangeInCapacity"
  autoscaling_group_name = aws_autoscaling_group.nexus-asg.name
}

# Creating an autoscaling group
resource "aws_autoscaling_group" "nexus-asg" {
  name                 = "nexus-asg"
  launch_configuration = aws_launch_configuration.nexus-lc.id
  min_size             = var.min_instances
  max_size             = var.max_instances
  health_check_type    = "EC2"
  vpc_zone_identifier  = tolist([aws_default_subnet.subnet_1.id, aws_default_subnet.subnet_2.id])
  depends_on           = [aws_launch_configuration.nexus-lc]

  tag {
    key                 = "Name"
    value               = "nexus-asg"
    propagate_at_launch = true
  }
}

# Creating the launch configuration for the autoscaling group above
resource "aws_launch_configuration" "nexus-lc" {
  name            = "nexus-lc"
  image_id        = "ami-00399ec92321828f5"
  instance_type   = "t2.micro"
  key_name        = "Default"
  security_groups = ["${aws_security_group.nexus-asg-sg.id}"]
  iam_instance_profile = "s3_access_profile"

  user_data = <<-EOF
              #!/bin/bash
              sudo apt-get update -y && sudo apt-get upgrade -y
              sudo apt-get install awscli -y
              sudo apt-get install apache2 -y
              sudo systemctl start apache2
              sudo aws s3 cp s3://websitedatanexus/index.html /var/www/html/
              EOF

  lifecycle {
    create_before_destroy = true
  }
}

# Creating Cloudwatch Alarm for Autoscaling Group
resource "aws_cloudwatch_metric_alarm" "CPU" {
  alarm_name          = "High_CPU_Utilization"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120"
  statistic           = "Average"
  threshold           = "85"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.nexus-asg.name
  }

  alarm_description = "This metric monitors ec2 cpu utilization"
  alarm_actions     = [aws_autoscaling_policy.nexus-asg-policy-1.arn]
}

#Creating the Target Group for the Load Balancer
resource "aws_lb_target_group" "nexus-lb-tg" {
  name     = "nexus-lb-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_default_vpc.production.id
}

# Creating the Application Load Balancer
resource "aws_lb" "nexus-lb" {
  name               = "nexus-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = ["${aws_security_group.nexus-lb-sg.id}"]
  subnets            = tolist([aws_default_subnet.subnet_1.id, aws_default_subnet.subnet_2.id])
}

# Attaching the LB to the ASG
resource "aws_autoscaling_attachment" "nexus-asg-attachment-lb" {
  autoscaling_group_name = aws_autoscaling_group.nexus-asg.id
  alb_target_group_arn   = aws_lb_target_group.nexus-lb-tg.arn
}

# Creating the listener for the Load Balancer
resource "aws_lb_listener" "nexus-lb-listener" {
  load_balancer_arn = aws_lb.nexus-lb.id
  port              = var.server_port
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nexus-lb-tg.arn
  }
}

# Creating a security group that is applied to the launch configuration
resource "aws_security_group" "nexus-asg-sg" {
  name   = "nexus-asg-sg"
  vpc_id = aws_default_vpc.production.id

  # Inbound HTTP from VPC
  ingress {
    from_port   = var.server_port
    to_port     = var.server_port
    protocol    = "tcp"
    cidr_blocks = ["172.31.0.0/16"]
  }
  # Inbound SSH access from Management Subnet
  ingress {
    from_port   = var.ssh_port
    to_port     = var.ssh_port
    protocol    = "tcp"
    cidr_blocks = ["172.31.32.0/20"]
  }
  # Outbound All Allowed
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Creating a Security Group that is applied to the LB
resource "aws_security_group" "nexus-lb-sg" {
  name   = "nexus-lb-sg"
  vpc_id = aws_default_vpc.production.id

  # Allow all outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Inbound HTTP from anywhere
  ingress {
    from_port   = var.server_port
    to_port     = var.server_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

