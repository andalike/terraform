provider "aws" {
  access_key = "Access-Key"
  secret_key = "Secret-Key"
  region     = "ap-south-1"
}

resource "aws_instance" "web" {
  ami           = var.instance_ami
  instance_type = var.instance_type

  tags = {
    Name = "instance-1"
  }
}