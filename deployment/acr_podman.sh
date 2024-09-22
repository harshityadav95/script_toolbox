## Deploy Podman image to azure container registry 

# Variables  
ACR_NAME=<your-registry-name>  
IMAGE_NAME=<your-image-name>  
IMAGE_TAG=<your-image-tag>  
  
# Azure login  
az login  
  
# Enable admin user  
az acr update --name $ACR_NAME --admin-enabled true  
  
# Get ACR details  
ACR_LOGIN_SERVER=$(az acr show --name $ACR_NAME --query loginServer --output tsv)  
ACR_USERNAME=$(az acr credential show --name $ACR_NAME --query username --output tsv)  
ACR_PASSWORD=$(az acr credential show --name $ACR_NAME --query passwords[0].value --output tsv)  
  
# Podman login  
podman login $ACR_LOGIN_SERVER --username $ACR_USERNAME --password $ACR_PASSWORD  
  
# Build and tag image  
podman build -t $IMAGE_NAME:$IMAGE_TAG .  
podman tag $IMAGE_NAME:$IMAGE_TAG $ACR_LOGIN_SERVER/$IMAGE_NAME:$IMAGE_TAG  
  
# Push image  
podman push $ACR_LOGIN_SERVER/$IMAGE_NAME:$IMAGE_TAG  
  
# Verify (optional)  
az acr repository list --name $ACR_NAME --output table  
