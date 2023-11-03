data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"]
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

# Public Subnet
resource "aws_subnet" "public" {
  count                   = 3
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index}.0/24"
  map_public_ip_on_launch = true
  availability_zone       = element(data.aws_availability_zones.available.names, count.index)
}

# Elastic IP
resource "aws_eip" "nat" {
  count = 3
  vpc   = true
}

# NAT Gateway 
resource "aws_nat_gateway" "nat" {
  count         = 3
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  depends_on    = [aws_internet_gateway.igw]
}

# Route Table and Association For Public
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public" {
  count          = 3
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private Subnet
resource "aws_subnet" "private" {
  count             = 3
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 3}.0/24"
  availability_zone = element(data.aws_availability_zones.available.names, count.index)
}

# Route Table and Association For Private
resource "aws_route_table" "private" {
  count  = 3
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat[count.index].id
  }
}

resource "aws_route_table_association" "private" {
  count          = 3
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_launch_configuration" "web_config" {
  name_prefix     = "web-"
  image_id        = data.aws_ami.ubuntu.id
  instance_type   = "t3a.small"
  security_groups = [aws_security_group.allow_web.id]

  user_data = <<-EOF
              #!/bin/bash
              sudo apt-get update
              sudo apt-get install -y apache2
              sudo systemctl start apache2
              sudo systemctl enable apache2
              echo "<h1>Apache Server</h1>" | sudo tee /var/www/html/index.html
              EOF

}


resource "aws_autoscaling_group" "web_asg" {
  launch_configuration      = aws_launch_configuration.web_config.id
  vpc_zone_identifier       = flatten([aws_subnet.public[*].id])
  min_size                  = 2
  max_size                  = 10
  health_check_type         = "EC2"
  desired_capacity          = 2
  force_delete              = true
  health_check_grace_period = 300
  tag {
    key                 = "Name"
    value               = "webserver"
    propagate_at_launch = true
  }
}

resource "aws_security_group" "allow_web" {
  name        = "allow_web"
  description = "Security group for web servers"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


resource "aws_elb" "web_elb" {
  name            = "web-load-balancer"
  subnets         = flatten([aws_subnet.public[*].id])
  security_groups = [aws_security_group.allow_web.id]

  listener {
    instance_port     = 80
    instance_protocol = "http"
    lb_port           = 80
    lb_protocol       = "http"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3
    target              = "HTTP:80/"
    interval            = 30
  }


  cross_zone_load_balancing   = true
  idle_timeout                = 400
  connection_draining         = true
  connection_draining_timeout = 400
}
resource "aws_autoscaling_attachment" "web_asg_attachment" {
  autoscaling_group_name = aws_autoscaling_group.web_asg.name
  elb                    = aws_elb.web_elb.name
}
