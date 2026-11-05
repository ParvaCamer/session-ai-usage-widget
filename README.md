# Widget d'utilisation Claude

Affiche en permanence le pourcentage utilisé de ton forfait Claude (session et semaine) et le moment de la réinitialisation.

Projet personnel non officiel, sans lien avec Anthropic.

## macOS (13 ou plus récent)

```bash
curl -fsSL https://raw.githubusercontent.com/ParvaCamer/claude-usage-widget/main/mac/install.sh | bash
```

La commande compile le widget sur ton Mac à partir de ces sources, puis l'installe dans `Applications`. Si les outils de ligne de commande Apple manquent, elle propose de les installer : relance-la ensuite. Tu peux lire [le script](mac/install.sh) avant de le lancer.

Le pourcentage apparaît dans la barre de menu, et le widget sur le bureau. Clique dessus pour te connecter à claude.ai, puis glisse-le où tu veux. Le clic droit et le menu de la barre donnent accès aux options.

Ce n'est pas un widget du centre de notifications d'Apple (WidgetKit) : ce format exige un projet Xcode et ne permet pas de se connecter à claude.ai. C'est une petite fenêtre posée au niveau du bureau.

## Windows 10 ou 11

1. Télécharge ce dépôt (`Code` > `Download ZIP`) et décompresse-le à l'endroit où il restera.
2. Double-clique sur `windows/build.bat`. Rien à installer : le compilateur fait partie de Windows.
3. Lance `windows/ClaudeUsage.exe`, puis clique sur le widget pour te connecter à claude.ai.

Les 3 DLL doivent rester à côté du `.exe`. Si « Continuer avec Google » est refusé dans la fenêtre de connexion, utilise « Continuer avec l'e-mail ».

| Action | Effet |
| --- | --- |
| Glisser | Déplace le widget (position mémorisée) |
| Clic | Actualise, ou ouvre la connexion si elle est demandée |
| Clic droit | Menu : actualiser, compte, premier plan, lancement avec l'app Claude, quitter |

**Pendant un jeu :** le widget se masque seulement si le plein écran occupe le même écran que lui, et réapparaît sans prendre le focus. Sur l'autre écran, il reste affiché et continue de se mettre à jour. Une vidéo en plein écran a le même effet.

**Avec l'app Claude :** l'option « Se lancer avec l'app Claude » démarre le widget avec Windows. Il reste invisible et presque sans consommation tant que l'app est fermée, puis apparaît quand tu l'ouvres, quelle que soit la façon de l'ouvrir. L'app Claude réduite dans la zone de notification compte comme ouverte. Si tu cliques sur « Quitter », le widget ne revient qu'au prochain démarrage de Windows, ou en relançant le `.exe`. Cette option n'existe que sous Windows.

## Bon à savoir

- **Source des données :** la même adresse que la page Paramètres > Utilisation de claude.ai, lue toutes les 5 minutes avec ta propre session. Elle n'est pas documentée par Anthropic et peut changer sans préavis, ce qui casserait le widget. À toi de voir si cet usage te convient au regard des conditions d'utilisation de Claude.
- **Ta connexion :** le widget ne voit pas ton mot de passe et ne contacte que claude.ai pour lire tes chiffres. La session reste sur ta machine, comme dans un navigateur :
  - Windows : `%LOCALAPPDATA%\ClaudeUsageWidget\web`
  - macOS : données WebKit de l'application
- **Mémoire sous Windows :** environ 150 à 190 Mo (programme et moteur Edge WebView2).
- **Si une connexion est redemandée sans raison (Windows) :** `%LOCALAPPDATA%\ClaudeUsageWidget\journal.txt` indique pourquoi (états et codes HTTP uniquement, sans aucun contenu ni identifiant).

## Désinstaller

**Windows**

1. Clic droit sur le widget : décoche « Se lancer avec l'app Claude », puis Quitter.
2. Supprime ce dossier et `%LOCALAPPDATA%\ClaudeUsageWidget` (efface aussi ta session).

**macOS**

1. Dans le menu du widget : décoche le lancement à l'ouverture de session, puis Quitter.
2. Supprime `Claude Usage` du dossier `Applications`.

## Licences

Le code de ce dépôt est sous [licence MIT](LICENSE). Les DLL de `windows/` appartiennent à Microsoft et ont leur propre licence : [WebView2-LICENSE.txt](windows/WebView2-LICENSE.txt) et [WebView2-NOTICE.txt](windows/WebView2-NOTICE.txt).
