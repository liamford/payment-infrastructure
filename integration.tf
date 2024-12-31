resource "aws_security_group" "vpc_link" {
  name   = "vpc-link"
  vpc_id = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_apigatewayv2_vpc_link" "eks" {
  name               = "eks"
  security_group_ids = [aws_security_group.vpc_link.id]
  subnet_ids = [
    aws_subnet.private-ap-southeast-2a.id,
    aws_subnet.private-ap-southeast-2b.id
  ]
}

resource "aws_apigatewayv2_integration" "eks" {
  api_id = aws_apigatewayv2_api.main.id

  integration_uri    = "arn:aws:elasticloadbalancing:ap-southeast-2:765874878578:listener/net/adacc4dd0e03747bf8e8ee6ef2c560a9/2c21539d1540b901/44b15c9d0c8460ad"
  integration_type   = "HTTP_PROXY"
  integration_method = "ANY"
  connection_type    = "VPC_LINK"
  connection_id      = aws_apigatewayv2_vpc_link.eks.id
}

resource "aws_apigatewayv2_route" "get_health" {
  api_id = aws_apigatewayv2_api.main.id

  route_key = "GET /api/payments/v1/actuator/health"
  target    = "integrations/${aws_apigatewayv2_integration.eks.id}"
}

output "health_base_url" {
  value = "${aws_apigatewayv2_stage.prod.invoke_url}/api/payments/v1/actuator/health"
}
