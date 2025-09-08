pipeline {
  agent any
  options { timestamps() }
  environment {
    AWS_REGION     = 'us-east-2'
    DOCKER_IMAGE   = 'snigdha415/devops-app'
    CONTAINER_NAME = 'devops_app_container'
  }

  stages {
    stage('Checkout') { steps { checkout scm } }

    stage('Build Docker') {
      steps { sh 'docker build -t $DOCKER_IMAGE:${BUILD_NUMBER} .' }
    }

    stage('Push to Docker Hub') {
      steps {
        withCredentials([usernamePassword(credentialsId: 'dockerhub-creds',
                                          usernameVariable: 'DH_USER',
                                          passwordVariable: 'DH_PASS')]) {
          sh '''
            echo "$DH_PASS" | docker login -u "$DH_USER" --password-stdin
            docker push $DOCKER_IMAGE:${BUILD_NUMBER}
            docker tag  $DOCKER_IMAGE:${BUILD_NUMBER} $DOCKER_IMAGE:latest
            docker push $DOCKER_IMAGE:latest
          '''
        }
      }
    }

    stage('Redeploy via SSM') {
      steps {
        withCredentials([usernamePassword(credentialsId: 'aws-access-key',
                                          usernameVariable: 'AWS_ACCESS_KEY_ID',
                                          passwordVariable: 'AWS_SECRET_ACCESS_KEY')]) {
          sh '''
            set -e
            IID=$(aws ec2 describe-instances --region $AWS_REGION \
              --filters "Name=tag:Name,Values=DevOpsWebApp" "Name=instance-state-name,Values=running" \
              --query "Reservations[0].Instances[0].InstanceId" --output text)
            echo "InstanceId: $IID"

            CMD_ID=$(aws ssm send-command --region $AWS_REGION \
              --document-name AWS-RunShellScript --instance-ids "$IID" \
              --parameters commands="docker pull $DOCKER_IMAGE:latest; docker rm -f $CONTAINER_NAME || true; docker run -d --name $CONTAINER_NAME --restart always -p 80:5000 $DOCKER_IMAGE:latest" \
              --query "Command.CommandId" --output text)
            echo "CommandId: $CMD_ID"

            # Poll SSM status until Success (or fail fast)
            for i in {1..30}; do
              STATUS=$(aws ssm list-command-invocations --region $AWS_REGION --command-id "$CMD_ID" \
                       --query "CommandInvocations[0].Status" --output text || true)
              echo "SSM status: $STATUS"
              if [ "$STATUS" = "Success" ]; then break; fi
              if [ "$STATUS" = "Failed" ] || [ "$STATUS" = "TimedOut" ] || [ "$STATUS" = "Cancelled" ]; then
                echo "SSM command failed: $STATUS"
                exit 1
              fi
              sleep 2
            done

            # brief settle so the container can start
            sleep 3
          '''
        }
      }
    }

    stage('Smoke Test Live') {
      steps {
        withCredentials([usernamePassword(credentialsId: 'aws-access-key',
                                          usernameVariable: 'AWS_ACCESS_KEY_ID',
                                          passwordVariable: 'AWS_SECRET_ACCESS_KEY')]) {
          sh '''
            set -e
            DNS=$(aws ec2 describe-instances --region $AWS_REGION \
              --filters "Name=tag:Name,Values=DevOpsWebApp" "Name=instance-state-name,Values=running" \
              --query "Reservations[0].Instances[0].PublicDnsName" --output text)
            echo "Hitting http://$DNS/ ..."
            curl -I "http://$DNS/" | head -n 1
            curl -fsS "http://$DNS/" | head -c 200 || (echo "App not responding" && exit 1)
          '''
        }
      }
    }
  }
}
