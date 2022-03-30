provider "aws" {
  region = var.aws_region
  default_tags {
    tags = var.common_tags
  }
}

variable "aws_region" {
  type = string
}

variable "common_tags" {
  type        = map(string)
  description = "To be applied to all taggable AWS resources"
}

# Get DNS and cert output from -cert workspace
data "tfe_outputs" "cert" {
  organization = "richard-russell-org"
  workspace    = "aws-omnidroid-cert"  
}

# Networking
# Create a VPC to launch our instances into
resource "aws_vpc" "default" {
  cidr_block = "10.0.0.0/16"
}

# Create an internet gateway to give our subnet access to the outside world
resource "aws_internet_gateway" "default" {
  vpc_id = aws_vpc.default.id
}

# Grant the VPC internet access on its main route table
resource "aws_route" "internet_access" {
  route_table_id         = aws_vpc.default.main_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.default.id
}

resource "aws_subnet" "instance" {
  vpc_id                  = aws_vpc.default.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "eu-west-1a"
  map_public_ip_on_launch = true
}

resource "aws_subnet" "lb" {
  vpc_id                  = aws_vpc.default.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "eu-west-1a"
  map_public_ip_on_launch = true
}

resource "aws_security_group" "default" {
  name        = "omnidroid_default"
  description = "Default security group"
  vpc_id      = aws_vpc.default.id

  # SSH access from anywhere
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS access from anwywhere
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
# Launch an Amazon Linux 2 instance
data "aws_ami" "amazon-2" {
  most_recent = true

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-ebs"]
  }
  owners = ["amazon"]
}

resource "aws_instance" "https_server" {
  ami           = data.aws_ami.amazon-2.id
  instance_type = "t2.micro"
  key_name      = "KeyVanCleef"

  tags = {
    Name = "https-server"
  }

  vpc_security_group_ids = [aws_security_group.default.id]
  subnet_id              = aws_subnet.instance.id

  user_data = <<-EOF
#!/bin/bash -v
yum install -y httpd
systemctl start httpd &&  systemctl enable httpd
yum install -y mod_ssl
cd /etc/pki/tls/certs
./make-dummy-cert localhost.crt
sed -i '/SSLCertificateKeyFile \/etc\/pki\/tls\/private\/localhost.key/s/^/#/' /etc/httpd/conf.d/ssl.conf
systemctl restart httpd
EOF
}

# NLB
resource "aws_lb" "lb" {
  name               = "omnidroid-lb"
  internal           = false
  load_balancer_type = "network"
  subnets            = [aws_subnet.lb.id]

}

resource "aws_lb_target_group" "target" {
  name     = "omnidroid-lb-tg"
  port     = 443
  protocol = "TCP"
  vpc_id   = aws_vpc.default.id
}

resource "aws_lb_target_group_attachment" "omnidroid_tga" {
  target_group_arn = aws_lb_target_group.target.arn
  target_id        = aws_instance.https_server.id
  port             = 443
}

resource "aws_lb_listener" "front_end" {
  load_balancer_arn = aws_lb.lb.arn
  port              = "443"
  protocol          = "TCP"
#   ssl_policy        = "ELBSecurityPolicy-2016-08"
#   certificate_arn   = "arn:aws:acm:eu-west-1:019165562641:certificate/1b04e6d6-5107-478a-94c5-69ebc6139fd1"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.target.arn
  }
}

resource "aws_route53_record" "omnidroid" {
  zone_id = data.tfe_outputs.cert.values.dns_zone_id
  name    = "lb"
  type    = "A"

  alias {
    name                   = aws_lb.lb.dns_name
    zone_id                = aws_lb.lb.zone_id
    evaluate_target_health = true
  }
}


output "server_url" {
  value = "https://${aws_instance.https_server.public_ip}"
}

output "lb_url" {
  value = "https://${aws_lb.lb.dns_name}"
}