# Widget d'utilisation Claude

Affiche en permanence le pourcentage utilisé de tes forfaits **Claude** et **Codex** (session, semaine ou mois selon le forfait) et le moment de la réinitialisation.

Projet personnel non officiel, sans lien avec Anthropic ni OpenAI. Les petites mascottes en pixel art sont des créations originales, pas les logos officiels.

## Quels outils ?

- **Claude :** connecte-toi une fois à claude.ai en cliquant sur le widget.
- **Codex :** rien à faire si Codex (l'app ou la ligne de commande) est installé et connecté. Le widget lui demande ses limites directement, sans connexion de son côté.

Le menu (clic droit, ou barre de menu sur Mac) permet de cocher les outils à afficher. Au premier lancement, seuls ceux qui sont détectés sur l'ordinateur s'affichent.

## Téléchargement direct

La page [Releases](https://github.com/ParvaCamer/claude-usage-widget/releases/latest) propose des fichiers prêts à l'emploi, fabriqués automatiquement par GitHub à partir de ce code :

- **Windows :** `ClaudeUsage-Windows.zip`. Décompresse-le à l'endroit où il restera, puis lance `ClaudeUsage.exe`.
- **macOS :** `ClaudeUsage-macOS.dmg`. Ouvre-le et glisse `Claude Usage` dans `Applications`. Il fonctionne sur les Mac Apple Silicon et Intel.

Ces fichiers ne sont pas signés par un certificat payant, donc le système affiche un avertissement au premier lancement :

- **Windows :** clique sur « Informations complémentaires », puis « Exécuter quand même ».
- **macOS :** ouvre l'app une première fois. Si macOS la bloque, va dans Réglages Système > Confidentialité et sécurité, puis clique sur « Ouvrir quand même ».

Sur Mac, la commande ci-dessous évite cet avertissement, puisque l'app est compilée directement sur ton Mac.

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
| Clic droit | Menu : actualiser, compte Claude, outils affichés, premier plan, lancement automatique, quitter |

**Pendant un jeu :** le widget se masque seulement si le plein écran occupe le même écran que lui, et réapparaît sans prendre le focus. Sur l'autre écran, il reste affiché et continue de se mettre à jour. Une vidéo en plein écran a le même effet.

**Avec l'app Claude ou Codex :** l'option « Se lancer avec l'app Claude ou Codex » démarre le widget avec Windows. Il reste invisible et presque sans consommation tant qu'aucune des deux apps cochées n'est ouverte, puis apparaît quand tu en ouvres une, quelle que soit la façon de l'ouvrir. Une app réduite dans la zone de notification compte comme ouverte. Si tu cliques sur « Quitter », le widget ne revient qu'au prochain démarrage de Windows, ou en relançant le `.exe`. Cette option n'existe que sous Windows.

## Bon à savoir

- **Codex :** les limites viennent de Codex lui-même (son app-server), lancé en arrière-plan sans fenêtre toutes les 2 minutes. Le widget ne lit ni ne stocke aucun jeton Codex.
- **Claude :** la même adresse que la page Paramètres > Utilisation de claude.ai, lue toutes les 2 minutes avec ta propre session. Elle n'est pas documentée par Anthropic et peut changer sans préavis, ce qui casserait le widget. À toi de voir si cet usage te convient au regard des conditions d'utilisation de Claude.
- **Ta connexion :** le widget ne voit pas ton mot de passe et ne contacte que claude.ai pour lire tes chiffres. La session reste sur ta machine, comme dans un navigateur :
  - Windows : `%LOCALAPPDATA%\ClaudeUsageWidget\web`
  - macOS : données WebKit de l'application
- **Mémoire sous Windows :** environ 150 à 190 Mo (programme et moteur Edge WebView2).
- **Si une connexion est redemandée sans raison (Windows) :** `%LOCALAPPDATA%\ClaudeUsageWidget\journal.txt` indique pourquoi (états et codes HTTP uniquement, sans aucun contenu ni identifiant).

## Désinstaller

**Windows**

1. Clic droit sur le widget : décoche « Se lancer avec l'app Claude ou Codex », puis Quitter.
2. Supprime ce dossier et `%LOCALAPPDATA%\ClaudeUsageWidget` (efface aussi ta session).

**macOS**

1. Dans le menu du widget : décoche le lancement à l'ouverture de session, puis Quitter.
2. Supprime `Claude Usage` du dossier `Applications`.

## Licences

Le code de ce dépôt est sous [licence MIT](LICENSE). Les DLL de `windows/` appartiennent à Microsoft et ont leur propre licence : [WebView2-LICENSE.txt](windows/WebView2-LICENSE.txt) et [WebView2-NOTICE.txt](windows/WebView2-NOTICE.txt).
