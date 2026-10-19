"""HAL en serveur MCP                                                   (partie F)

Claude Code, Gemini CLI ou Claude Desktop lisent HAL depuis la machine de
l'utilisateur, avec une clé à eux (MCP-2). Les outils sont ceux du coach, et
ceux du planning et de la maison en plus : un outil n'existe qu'une fois. La
base décide comme pour l'appli, et rien ne change sans l'accord de
l'utilisateur (ACC) : ce lot n'ouvre que la lecture, la mémoire, la mesure dite
et le résumé d'une conversation.

    cles.py        les clés des clients et leurs sessions
    catalogue.py   les outils du profil externe, et la consigne courte
    serveur.py     le serveur MCP, sa porte et son cycle de vie
"""
