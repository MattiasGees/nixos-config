{ pkgs, ... }:
with pkgs;
{
  home = {
    packages = with pkgs; [
      # all the kubernetes related stuff
      kubectx kubectl awscli2 (google-cloud-sdk.withExtraComponents [google-cloud-sdk.components.gke-gcloud-auth-plugin]) kustomize
      helmfile kubernetes-helm k9s crane kind awscli2 cosign istioctl k3d
      # argo-workflows argocd kubectx kubectl awscli2 (google-cloud-sdk.withExtraComponents [google-cloud-sdk.components.gke-gcloud-auth-plugin]) kustomize
      # helmfile kubernetes-helm k9s crane minikube kind awscli2 cosign syft grype ko cmctl dive tilt stern skaffold
    ];
  };
}
