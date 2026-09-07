# Branding YesWeSync — optionnel, post-déploiement

## IMPORTANT

Le déploiement principal (Dockerfile racine + docker-compose.yml) utilise
l'UI Airbyte **officielle et non modifiée**.

Le branding YesWeCange nécessite de patcher le bundle JAR d'Airbyte
(`jar uf` sur `io.airbyte-airbyte-server-2.2.0.jar`).

Ce n'est **pas une modification de code source Airbyte**, mais une modification
d'un artefact binaire build-time. C'est reproductible (via Docker build),
mais constitue une déviation de l'image officielle.

**Décision à prendre séparément, après le déploiement fonctionnel.**

## Si vous activez le branding

1. Copier `Dockerfile.branding` à la place du `Dockerfile` racine
2. Copier `yeswecange-mark.png` et `yeswecange-branding.css` dans ce dossier
3. Rebuilder l'image : `docker compose build server`
4. Redéployer dans Coolify

Les assets branding sont disponibles dans :
```
yeswereport/airbyte-branding/
  Dockerfile.yeswesync        → Dockerfile de branding (patch JAR)
  yeswecange-branding.css     → overlay CSS Airbyte 2.2.0
  yeswecange-mark.png         → logo YesWeCange
```

## Avertissement version

Les sélecteurs CSS dans `yeswecange-branding.css` ciblent les class names
compilés d'Airbyte **2.2.0 spécifiquement**. Tout upgrade Airbyte nécessite
de vérifier et mettre à jour le CSS.
