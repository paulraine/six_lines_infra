provider "aws" {
    region = "us-west-2"
}

###################### IAM ######################
resource "aws_iam_role" "ecs_task_role" {
    name = "ecs-task-role"

    assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
        {
            Action = "sts:AssumeRole"
            Effect = "Allow"
            Principal = {
            Service = "ecs-tasks.amazonaws.com"
            }
        }
        ]
    })
}

resource "aws_iam_policy" "ecs_task_policy" {
    name = "ecs-task-policy"

    policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
        {
            Action = [
            "dynamodb:PutItem",
            "dynamodb:GetItem",
            "dynamodb:DeleteItem",
            "dynamodb:Scan",
            "dynamodb:Query",
            "ecr:GetAuthorizationToken",
            "ecr:BatchCheckLayerAvailability",
            ]
            Effect = "Allow"
            Resource = "*"
        }
        ]
    })
}

resource "aws_iam_role_policy_attachment" "ecs_task_policy_attachment" {
    policy_arn = aws_iam_policy.ecs_task_policy.arn
    role       = aws_iam_role.ecs_task_role.name
}

###################### VPC ######################
resource "aws_vpc" "six_lines_vpc" {
    cidr_block = "10.0.0.0/16"
    # Add any other VPC configuration options here if required
}

resource "aws_subnet" "six_lines_subnet_1" {
    cidr_block = "10.0.12.0/24"
    vpc_id     = aws_vpc.six_lines_vpc.id
    availability_zone = "us-west-2a"  # Replace with an AZ in your desired region
}

resource "aws_subnet" "six_lines_subnet_2" {
    cidr_block = "10.0.24.0/24"
    vpc_id     = aws_vpc.six_lines_vpc.id
    availability_zone = "us-west-2b"  # Replace with another AZ in your desired region
}

resource "aws_internet_gateway" "six_lines_igw" {
    vpc_id = aws_vpc.six_lines_vpc.id
}

resource "aws_route_table" "six_lines_route_table" {
    vpc_id = aws_vpc.six_lines_vpc.id

    route {
        cidr_block = "0.0.0.0/0"
        gateway_id = aws_internet_gateway.six_lines_igw.id
    }
}

# Create a route table association for the first subnet
resource "aws_route_table_association" "six_lines_subnet_association_1" {
    subnet_id      = aws_subnet.six_lines_subnet_1.id
    route_table_id = aws_route_table.six_lines_route_table.id
}

# Create a route table association for the second subnet
resource "aws_route_table_association" "six_lines_subnet_association_2" {
    subnet_id      = aws_subnet.six_lines_subnet_2.id
    route_table_id = aws_route_table.six_lines_route_table.id
}

###################### DYNAMODB ######################
resource "aws_dynamodb_table" "users_table" {
    name = "users"
    billing_mode = "PAY_PER_REQUEST"

    attribute {
        name = "email"
        type = "S"
    }

    hash_key = "email"
}

resource "aws_dynamodb_table" "prompts_table" {
    name = "prompts"
    billing_mode = "PAY_PER_REQUEST"

    attribute {
        name = "prompt_id"
        type = "S"
    }

    hash_key = "prompt_id"
}

resource "aws_dynamodb_table" "poems_table" {
    name = "poems"
    billing_mode = "PAY_PER_REQUEST"

    attribute {
        name = "poem_id"
        type = "S"
    }

    hash_key = "poem_id"
}

###################### ECR ######################
resource "aws_ecr_repository" "six_lines_ecr_repository" {
    name = "six-lines-ecr-repository"
    image_tag_mutability = "MUTABLE"  # Optional: Set the image tag mutability (default is "MUTABLE")
    image_scanning_configuration {
        scan_on_push = true  # Enable image scanning on push (requires an ECR scan on push capability)
    }
}

###################### ALB ######################
# Create an Application Load Balancer (ALB)
resource "aws_lb" "six_lines_alb" {
    name               = "six-lines-alb"
    load_balancer_type = "application"
    subnets            = [aws_subnet.six_lines_subnet_1.id, aws_subnet.six_lines_subnet_2.id]
}

# Create a target group for the load balancer
resource "aws_lb_target_group" "six_lines_target_group" {
    name        = "six-lines-target-group"
    port        = 80
    protocol    = "HTTP"
    target_type = "ip"
    vpc_id      = aws_vpc.six_lines_vpc.id
}

# Create a listener for the load balancer
resource "aws_lb_listener" "six_lines_listener" {
    load_balancer_arn = aws_lb.six_lines_alb.arn
    port              = 80
    protocol          = "HTTP"

    default_action {
        target_group_arn = aws_lb_target_group.six_lines_target_group.arn
        type             = "forward"
    }
}

###################### ECS ######################
# Create an ECS cluster
resource "aws_ecs_cluster" "six_lines_cluster" {
    name = "six-lines-cluster"
}

# Define the ECS task using a task definition
resource "aws_ecs_task_definition" "six_lines_task" {
    family = "six-lines-task"
    network_mode = "awsvpc"  # Specify the network mode as awsvpc
    
    cpu = 256  # Specify the CPU requirement for the container (in units of CPU shares)
    memory = 512  # Specify the maximum memory that the container can use (in MiB)

    # Add the execution role ARN required for pulling ECR images
    execution_role_arn = aws_iam_role.ecs_task_role.arn

    container_definitions = jsonencode([
        {
            name = "six-lines"
            image = "${aws_ecr_repository.six_lines_ecr_repository.repository_url}:latest"  # Specify the image
            portMappings = [
                {
                    containerPort = 80
                    hostPort      = 80
                }
            ]
            environment = [
                {
                    name  = "DYNAMODB_TABLE"
                    value = aws_dynamodb_table.users_table.name  # Pass the DynamoDB table name to the container
                },
            ]
        }
    ])
    requires_compatibilities = ["FARGATE"]  # Required for FARGATE
    # Add any other configuration options for your task definition here if required
}

###################### ECS SERVICE ######################
# Create an ECS service with a load balancer
resource "aws_ecs_service" "six_lines_service" {
    name            = "six-lines-service"
    cluster         = aws_ecs_cluster.six_lines_cluster.id
    task_definition = aws_ecs_task_definition.six_lines_task.arn
    desired_count   = 1
    launch_type     = "FARGATE"  # Specify the launch type as FARGATE

    # Set the network configuration for the ECS service using "awsvpc" network mode
    network_configuration {
        subnets          = [aws_subnet.six_lines_subnet_1.id, aws_subnet.six_lines_subnet_2.id]
    }

    # Add the load balancer configuration
    load_balancer {
        target_group_arn = aws_lb_target_group.six_lines_target_group.arn
        container_name   = "six-lines"
        container_port   = 80
    }
}